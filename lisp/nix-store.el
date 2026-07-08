;;; nix-store.el --- Browse the Nix store  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Thanos Apollo

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

;; A browser for objects in the Nix store, built on plain built-ins:
;; `special-mode' for the buffer, `outline-minor-mode' for foldable
;; sections and `button.el' for navigable store paths.  The old nix-mode
;; used magit-section and eieio; this drops both.
;;
;; The data layer is a set of tiny queries over `nix-store --query'.
;; `nix-store--query-all' composes them into one plist that fully
;; describes a path, and the render pipeline turns that plist into buffer
;; text.  Rendering reads only the plist, so it stays testable without a
;; real store.
;;
;; `nix-store-drv-mode' pretty-prints /nix/store/*.drv derivations as
;; JSON via "nix derivation show", restoring the raw file when the user
;; switches to another major mode.

;;; Code:

(require 'nix-core)
(require 'outline)
(require 'button)

;;; Customization

(defcustom nix-store-path-omit-self t
  "When non-nil, omit the path itself from its own reference lists.
The querying commands include the path in several lists (for
example a path is its own requisite); dropping it keeps the
sections focused on other paths."
  :type 'boolean
  :group 'nix)

(defcustom nix-store-sections
  '(outputs references referrers requisites derivers)
  "Ordered list of store sections rendered by `nix-store-path-mode'.
Each symbol names a key in the plist built by
`nix-store--query-all'.  Reorder or shorten the list to change
what a store-path buffer shows and in which order."
  :type '(repeat (choice (const outputs)
                         (const references)
                         (const referrers)
                         (const requisites)
                         (const derivers)))
  :group 'nix)

;;; Data layer

;; `nix-store--query' is the only edge that touches the store; every
;; other function here transforms its results.  The `--query FLAG PATH'
;; interface of nix-store returns one path per line, so line queries
;; reuse `nix--call-lines'.

(defun nix-store--query (path flag)
  "Return the lines of \"nix-store --query FLAG PATH\".
FLAG is a nix-store query option such as \"--references\"."
  (nix--call-lines nix-store-executable
                   (list "--query" flag path)
                   (format "nix-store --query %s" flag)))

(defun nix-store--deriver (path)
  "Return the deriver of PATH, or nil when it is unknown."
  (let ((deriver (car (nix-store--query path "--deriver"))))
    (and deriver (not (equal deriver "unknown-deriver")) deriver)))

(defun nix-store--size (path)
  "Return the size of the store PATH as a number."
  (string-to-number
   (car (nix-store--query path "--size"))))

(defun nix-store--hash (path)
  "Return the store hash of PATH."
  (car (nix-store--query path "--hash")))

(defun nix-store--outputs (path)
  "Return the outputs of PATH, or nil for a non-derivation path."
  (ignore-errors (nix-store--query path "--outputs")))

(defun nix-store--query-all (path)
  "Return a plist describing the store PATH.
The plist has keys :path :deriver :derivers :hash :size :outputs
:references :referrers :requisites, each populated from a single
nix-store query.  :derivers holds :deriver as a list, in the
shape the section renderer expects."
  (let ((deriver (nix-store--deriver path)))
    (list :path path
          :deriver deriver
          :derivers (and deriver (list deriver))
          :hash (nix-store--hash path)
          :size (nix-store--size path)
          :outputs (nix-store--outputs path)
          :references (nix-store--query path "--references")
          :referrers (nix-store--query path "--referrers")
          :requisites (nix-store--query path "--requisites"))))

;;; Rendering

(define-button-type 'nix-store-path-button
  'action #'nix-store--follow-button
  'follow-link t
  'help-echo "Show this store path")

(defun nix-store--follow-button (button)
  "Show the store path named by BUTTON."
  (nix-store-show-path (button-label button)))

(defun nix-store--section-title (section)
  "Return the heading text for SECTION, a symbol in `nix-store-sections'."
  (capitalize (symbol-name section)))

(defun nix-store--section-paths (data section)
  "Return the paths for SECTION from the query plist DATA.
Honor `nix-store-path-omit-self' by dropping the path itself."
  (let ((paths (plist-get data (intern (concat ":" (symbol-name section))))))
    (if nix-store-path-omit-self
        (remove (plist-get data :path) paths)
      paths)))

(defun nix-store--insert-header (data)
  "Insert the header block for the query plist DATA."
  (let ((path (plist-get data :path)))
    (insert (format "%-8s" "Path:"))
    (insert-text-button path :type 'nix-store-path-button)
    (insert "\n")
    (insert (format "%-8s%s\n" "Status:"
                    (if (file-exists-p path) "realised" "unrealised")))
    (insert (format "%-8s%s\n" "Hash:" (or (plist-get data :hash) "")))
    (insert (format "%-8s%s\n\n" "Size:"
                    (file-size-human-readable (plist-get data :size))))))

(defun nix-store--insert-section (data section)
  "Insert SECTION from the query plist DATA as an outline section.
The heading is an outline heading; each path is a button."
  (let ((paths (nix-store--section-paths data section)))
    (when paths
      (insert (nix-store--section-title section)
              (format " (%d)\n" (length paths)))
      (dolist (path paths)
        (insert "  ")
        (insert-text-button path :type 'nix-store-path-button)
        (insert "\n"))
      (insert "\n"))))

(defun nix-store--render (data)
  "Render the query plist DATA into the current buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (nix-store--insert-header data)
    (dolist (section nix-store-sections)
      (nix-store--insert-section data section))
    (goto-char (point-min))))

;;; Browser

(defvar-local nix-store--current-path nil
  "Store path shown in the current `nix-store-path-mode' buffer.")

(defvar-keymap nix-store-path-mode-map
  :doc "Keymap for `nix-store-path-mode'."
  "g" #'revert-buffer
  "RET" #'push-button
  "l" #'nix-store-show-log
  "r" #'nix-store-realise)

;; Only section headings like "References (12)" are outline headings;
;; the header block lines ("Path:", "Hash:", ...) also start at column 0
;; and must not fold, so the regexp requires the trailing count.
(defconst nix-store--outline-regexp "[A-Za-z]+ ([0-9]+)$"
  "Value of `outline-regexp' in `nix-store-path-mode'.")

(define-derived-mode nix-store-path-mode special-mode "Nix Store Path"
  "Major mode for browsing a path in the Nix store."
  :group 'nix
  (setq-local revert-buffer-function #'nix-store--revert)
  (setq-local outline-regexp nix-store--outline-regexp)
  (setq-local outline-level (lambda () 1))
  (setq-local outline-minor-mode-cycle t)
  (outline-minor-mode 1))

(defun nix-store--revert (&rest _)
  "Re-query and re-render the current store path buffer."
  (nix-store--render (nix-store--query-all nix-store--current-path)))

;;;###autoload
(defun nix-store-show-path (path)
  "Show information about the Nix store PATH in a dedicated buffer.
Sections are outline headings folded with TAB, and every store
path is a button that shows that path."
  (interactive "FNix store path: ")
  (let ((path (expand-file-name path)))
    (with-current-buffer (get-buffer-create
                          (format "*Nix Store Path: %s*" path))
      (nix-store-path-mode)
      (setq nix-store--current-path path)
      (nix-store--render (nix-store--query-all path))
      (pop-to-buffer (current-buffer)))))

(defun nix-store--path-at-point ()
  "Return the store path at point, or nil when there is none.
A store path is a filename under `nix-store-dir'."
  (when-let* ((name (thing-at-point 'filename t))
              (path (expand-file-name name)))
    (and (string-prefix-p (file-name-as-directory nix-store-dir) path)
         path)))

;;;###autoload
(defun nix-store-show-path-at-point ()
  "Show the Nix store path at point with `nix-store-show-path'."
  (interactive)
  (if-let* ((path (nix-store--path-at-point)))
      (nix-store-show-path path)
    (user-error "No Nix store path at point")))

;;;###autoload
(defun nix-store-realise (path)
  "Realise the Nix store PATH asynchronously.
Report on completion and refresh the buffer if it is still live."
  (interactive (list (or nix-store--current-path
                         (read-file-name "Realise store path: "))))
  (let ((buffer (current-buffer)))
    (nix--start nix-store-executable (list "--realise" path)
                (lambda (result)
                  (nix-store--realise-finish path buffer result)))))

(defun nix-store--realise-finish (path buffer result)
  "Report realisation of PATH from RESULT and refresh BUFFER if live."
  (if (eq (plist-get result :exit) 0)
      (progn
        (message "Realised %s" path)
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (when (derived-mode-p 'nix-store-path-mode)
              (revert-buffer)))))
    (message "Realising %s failed: %s"
             path (string-trim (plist-get result :stderr)))))

;;;###autoload
(defun nix-store-show-log ()
  "Show the build log of the current store path's deriver.
Signal a `user-error' when the path has no known deriver."
  (interactive)
  (let* ((path (or nix-store--current-path (nix-store--path-at-point)))
         (deriver (and path (or (and (string-suffix-p ".drv" path) path)
                                (nix-store--deriver path)))))
    (unless deriver
      (user-error "No derivation for this store path"))
    (nix-store--display-log deriver)))

(defun nix-store--display-log (drv)
  "Display the \"nix log\" output for DRV in a view buffer."
  (let ((log (nix--check (nix--call nix-executable (list "log" drv))
                         "nix log")))
    (with-current-buffer (get-buffer-create (format "*Nix Log: %s*" drv))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert log)
        (goto-char (point-min)))
      (view-mode 1)
      (pop-to-buffer (current-buffer)))))

;;; Derivation viewer

;;;###autoload
(add-to-list 'auto-mode-alist '("\\`/nix/store/.+\\.drv\\'" . nix-store-drv-mode))

;;;###autoload
(define-derived-mode nix-store-drv-mode js-json-mode "Nix-Derivation"
  "Major mode pretty-printing /nix/store/*.drv derivations as JSON.
The raw file is replaced with the output of \"nix derivation
show\"; switching to another major mode restores the original
file contents."
  (nix-store--drv-render)
  (add-hook 'change-major-mode-hook #'nix-store--drv-restore nil t))

(defun nix-store--drv-render ()
  "Replace the buffer with pretty JSON for the visited derivation."
  (let ((inhibit-read-only t)
        (json (json-encode (nix--derivation-show (buffer-file-name)))))
    (erase-buffer)
    (insert json)
    (json-pretty-print-buffer)
    (set-buffer-modified-p nil)
    (read-only-mode 1)))

(defun nix-store--drv-restore ()
  "Restore the raw derivation file when leaving `nix-store-drv-mode'."
  (remove-hook 'change-major-mode-hook #'nix-store--drv-restore t)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert-file-contents (buffer-file-name))
    (set-buffer-modified-p nil)
    (read-only-mode -1)))

(provide 'nix-store)
;;; nix-store.el ends here
