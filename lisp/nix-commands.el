;;; nix-commands.el --- Build, log, edit and search commands  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Thanos Apollo
;; Copyright (C) 2015-2023  The nix-mode contributors

;; Maintainer: Thanos Apollo <public@thanosapollo.org>

;; This file is a part of nix-mode.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; The four small "run a nix command" front-ends the old nix-mode kept in
;; separate files: `nix-build', `nix-log', `nix-edit' and `nix-search'.
;;
;; Every command splits into a pure `nix-<cmd>--args' argument builder and
;; a thin interactive wrapper that applies the process, buffer and UI
;; effects.  The argument builders and the output parsers (`nix-edit--parse',
;; `nix-search--render-entry') are the unit-test seam; nothing in the pure
;; layer touches a process or the filesystem.
;;
;; The read helpers `nix-commands--read-file', `nix-commands--read-attr'
;; and `nix-commands--read-flake' resolve a FILE, ATTR or flake reference,
;; preferring a dir-locals `nix-file' or `nix-flake' when set, then the
;; current buffer, then a prompt.

;;; Code:

(require 'compile)
(require 'nix-core)

;;; Interactive read helpers

(defcustom nix-search-flake "nixpkgs"
  "Default flake reference searched by `nix-search'."
  :type 'string
  :group 'nix)

;; `nix-file' and `nix-flake' are dir-locals variables (defined in the
;; nix-shell module).  Read them defensively so this module does not depend
;; on that one; `bound-and-true-p' returns nil when they are unset.

(defun nix-commands--read-file ()
  "Return a Nix file, preferring dir-locals and the current buffer.
Falls back to shell.nix or default.nix in `default-directory', then
to a prompt."
  (or (bound-and-true-p nix-file)
      (and (derived-mode-p 'nix-mode) buffer-file-name)
      (seq-find #'file-exists-p '("shell.nix" "default.nix"))
      (read-file-name "Nix file: " nil "<nixpkgs>")))

(defun nix-commands--read-attr (&optional prompt)
  "Read a Nix attribute path from the minibuffer, nil when empty.
PROMPT overrides the default \"Nix attribute: \" prompt."
  (let ((attr (read-string (or prompt "Nix attribute: "))))
    (and (not (string-empty-p attr)) attr)))

(defun nix-commands--read-flake ()
  "Return a Nix flake reference, preferring dir-locals and \"flake.nix\".
Falls back to a prompt defaulting to `nix-search-flake'."
  (or (bound-and-true-p nix-flake)
      (and (file-exists-p "flake.nix") ".")
      (read-string "Nix flake: " nix-search-flake)))

;;; nix-build

(defcustom nix-build-arguments nil
  "Extra arguments passed to every `nix-build' invocation."
  :type '(repeat string)
  :group 'nix)

(defun nix-build--args (file attr)
  "Build the nix-build argument list for FILE and ATTR.
ATTR, when non-nil, is passed as \"-A ATTR\".  Extra arguments from
`nix-build-arguments' come first."
  (append nix-build-arguments
          (list (nix--expand-file file))
          (and attr (list "-A" attr))))

(defun nix-build--buffer-name (file attr)
  "Return the compilation buffer name for FILE and ATTR."
  (format "*nix-build*<%s>" (or attr (file-name-nondirectory file))))

(defun nix-build--command (file attr)
  "Return the shell command string running nix-build on FILE and ATTR."
  (mapconcat #'shell-quote-argument
             (cons nix-build-executable (nix-build--args file attr))
             " "))

;;;###autoload
(defun nix-build (file &optional attr)
  "Build FILE with nix-build in a compilation buffer.
ATTR, when non-nil, selects an attribute of FILE with \"-A\"."
  (interactive (list (nix-commands--read-file)
                     (nix-commands--read-attr)))
  (let ((command (nix-build--command file attr))
        (name (nix-build--buffer-name file attr)))
    (compilation-start command nil (lambda (_mode) name))))

;;; nix-log

(defun nix-log--args (drv)
  "Return the \"nix log\" argument list for derivation DRV."
  (list "log" drv))

(defun nix-log--fetch (drv)
  "Return the build log of DRV via \"nix log\", or nil when empty.
Signals an error when \"nix log\" itself fails."
  (let ((log (string-trim (nix--check (nix--call nix-executable
                                                 (nix-log--args drv))
                                      "nix log"))))
    (and (not (string-empty-p log)) log)))

(defun nix-log--display (drv log)
  "Show LOG for derivation DRV in a read-only view buffer."
  (let ((buffer (get-buffer-create (format "*nix-log*<%s>" drv))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert log))
      (goto-char (point-min))
      (view-mode 1))
    (pop-to-buffer buffer)))

;;;###autoload
(defun nix-log (file &optional attr)
  "Show the build log of FILE via \"nix log\".
ATTR, when non-nil, selects an attribute of FILE.  FILE is
instantiated to a derivation whose log is fetched; errors when no
log is available."
  (interactive (list (nix-commands--read-file)
                     (nix-commands--read-attr)))
  (let* ((attr (and attr (not (string-empty-p attr)) attr))
         (drv (nix-instantiate file attr))
         (log (or (nix-log--fetch drv)
                  (user-error "No log is available for %s" drv))))
    (nix-log--display drv log)))

;;; nix-edit

(defun nix-edit--args (file attr)
  "Return the \"nix edit\" argument list for FILE and ATTR."
  (list "edit" "-f" (nix--expand-file file) attr))

(defun nix-edit--parse (output)
  "Parse OUTPUT of \"nix edit\" into a `(FILE . LINE)' cons.
LINE is an integer when OUTPUT ends in \":N\", nil otherwise.  A
Windows-style drive colon (\"C:/path\") is not treated as a line
separator.  Returns nil for empty OUTPUT."
  (let ((line (string-trim output)))
    (unless (string-empty-p line)
      (if (string-match "\\`\\(.+\\):\\([0-9]+\\)\\'" line)
          (cons (match-string 1 line)
                (string-to-number (match-string 2 line)))
        (cons line nil)))))

(defun nix-edit--locate (file attr)
  "Return the source location of ATTR in FILE as `(PATH . LINE)'.
Runs \"nix edit\" with EDITOR bound to \"echo\" so it prints the
target location instead of opening an editor."
  (let ((process-environment (cons "EDITOR=echo" process-environment)))
    (or (nix-edit--parse
         (nix--check (nix--call nix-executable (nix-edit--args file attr))
                     "nix edit"))
        (error "Command \"nix edit\" produced no output for %s" attr))))

;;;###autoload
(defun nix-edit (file attr)
  "Open the Nix source defining ATTR in FILE.
Uses \"nix edit\" to locate the definition, then visits it."
  (interactive (list (nix-commands--read-file)
                     (nix-commands--read-attr)))
  (pcase-let ((`(,path . ,line) (nix-edit--locate file attr)))
    (find-file path)
    (when line
      (goto-char (point-min))
      (forward-line (1- line)))))

;;; nix-search

(defface nix-search-pname
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for package names in the `nix-search' buffer."
  :group 'nix)

(defface nix-search-version
  '((t :inherit font-lock-constant-face))
  "Face for package versions in the `nix-search' buffer."
  :group 'nix)

(defface nix-search-description
  '((t :inherit font-lock-doc-face))
  "Face for package descriptions in the `nix-search' buffer."
  :group 'nix)

(defun nix-search--args (flake query)
  "Return the \"nix search\" argument list for FLAKE and QUERY."
  (append (list "search" flake)
          (and query (not (string-empty-p query)) (list query))
          (list "--json")))

(defun nix-search--fetch (flake query)
  "Return the parsed \"nix search\" results for FLAKE and QUERY.
The result is an alist mapping each attribute path symbol to its
entry alist (pname, version, description)."
  (nix--call-json nix-executable (nix-search--args flake query) "nix search"))

(defun nix-search--propertize (string face)
  "Return STRING propertized with FACE, or \"\" when STRING is nil."
  (if string (propertize string 'face face) ""))

(defun nix-search--render-entry (name entry)
  "Return the display string for search result NAME and ENTRY.
NAME is the attribute path symbol; ENTRY is its alist of pname,
version and description."
  (let-alist entry
    (concat (nix-search--propertize (or .pname (symbol-name name))
                                    'nix-search-pname)
            (nix-search--propertize (and .version (format " (%s)" .version))
                                    'nix-search-version)
            "\n"
            (nix-search--propertize .description 'nix-search-description)
            "\n\n")))

(defun nix-search--render (results)
  "Insert RESULTS into the current buffer as search entries."
  (dolist (result results)
    (insert (nix-search--render-entry (car result) (cdr result)))))

(defvar-local nix-search--flake nil
  "Flake reference searched in the current `nix-search' buffer.")

(defvar-local nix-search--query nil
  "Query searched in the current `nix-search' buffer.")

(define-derived-mode nix-search-mode special-mode "Nix-Search"
  "Major mode for displaying \"nix search\" results."
  :interactive nil
  :group 'nix)

(defun nix-search--revert (&rest _)
  "Re-run the search for the current buffer's flake and query."
  (nix-search--populate (current-buffer)
                        nix-search--flake nix-search--query))

(defun nix-search--populate (buffer flake query)
  "Fill BUFFER with the results of searching FLAKE for QUERY."
  (let ((results (nix-search--fetch flake query)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (nix-search--render results))
      (goto-char (point-min))
      (setq-local nix-search--flake flake
                  nix-search--query query
                  revert-buffer-function #'nix-search--revert))))

;;;###autoload
(defun nix-search (query &optional flake)
  "Search FLAKE for QUERY and show results in a `nix-search' buffer.
FLAKE defaults to `nix-search-flake' or a dir-locals `nix-flake'."
  (interactive (list (read-string "nix search: ")
                     (nix-commands--read-flake)))
  (let ((buffer (get-buffer-create "*nix-search*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'nix-search-mode)
        (nix-search-mode)))
    (nix-search--populate buffer (or flake nix-search-flake) query)
    (pop-to-buffer buffer)))

(provide 'nix-commands)
;;; nix-commands.el ends here
