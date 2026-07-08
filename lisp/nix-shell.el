;;; nix-shell.el --- Nix shell environments for nix-mode  -*- lexical-binding: t; -*-

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

;; A nix-shell emulator: apply the environment of a Nix derivation to an
;; Emacs buffer (or Eshell session) without leaving Emacs, ported from the
;; nix-shell.el of the unmaintained nix-mode.
;;
;; The port is organised around a pure core that never touches a process.
;; Given the alist decoded from "nix derivation show" (see
;; `nix--derivation-show'), `nix-shell--env', `nix-shell--inputs',
;; `nix-shell--exec-path' and `nix-shell--process-environment' compute the
;; store paths, the /bin directories and the PATH/env var list to apply.
;; These are the ERT seam.  The effectful edges -- `nix-shell',
;; `nix-eshell' and friends -- instantiate the derivation, then apply the
;; computed values buffer-locally, always copying `process-environment' and
;; `exec-path' rather than mutating the global values.
;;
;; A second, independent feature (`nix-eshell-integration-mode') follows
;; NixOS/nix-mode PR #202: it makes "nix develop" and "nix shell ..." run
;; inside Eshell mutate the current session's environment instead of
;; spawning a subshell, by capturing "... --command sh -c export" and
;; parsing the export lines (`nix-shell--parse-exports', also pure).
;;
;; Dropped from the old module: the exotic buffer-local extras it also set
;; from each input (`woman-manpath', `Man-header-file-path', `ffap-c-path',
;; `irony-additional-clang-options', the flycheck re-check).  This module
;; keeps the PATH/env core only; those integrations belong elsewhere.

;;; Code:

(require 'nix-core)

;; Set by `nix-shell'/`nix-eshell' effect edges and consumed by the Eshell
;; integration; forward-declared so the byte-compiler does not warn.
(defvar eshell-path-env)
(defvar eshell-path-env-list)

(declare-function eshell-mode "esh-mode")
(declare-function eshell-parse-command "esh-cmd")
(declare-function eshell-stringify-list "esh-util")

;;; Dir-locals variables

;; `nix-file' and `nix-attr' pin the Nix expression and attribute for a
;; project.  nix-commands.el reads `nix-file' via `bound-and-true-p', so it
;; must be defined here.  Both are marked safe as file-local values because
;; a string can only ever name a build target, never run code.

(defvar nix-file nil
  "Nix file to build expressions from.
Intended to be set in a .dir-locals.el or file-local variables
block; commands prefer it over prompting.")

(defvar nix-attr nil
  "Nix attribute path to build.
Intended to be set in a .dir-locals.el or file-local variables
block; commands prefer it over prompting.")

;; The autoload cookies register safety before the module loads (from the
;; generated autoloads); the bare `put' forms register it again when the
;; module is loaded directly, so both paths mark the vars safe.
;;;###autoload (put 'nix-file 'safe-local-variable #'stringp)
;;;###autoload (put 'nix-attr 'safe-local-variable #'stringp)
(put 'nix-file 'safe-local-variable #'stringp)
(put 'nix-attr 'safe-local-variable #'stringp)

;;; Customization

(defcustom nix-shell-inputs '(buildInputs
                              nativeBuildInputs
                              propagatedBuildInputs
                              propagatedNativeBuildInputs)
  "Derivation environment keys whose store paths enter the shell.
Each key names an environment variable in the derivation whose
value is a space-separated list of store paths."
  :type '(repeat symbol)
  :group 'nix)

(defcustom nix-shell-clear-environment nil
  "When non-nil, start from an empty environment, like nix-shell --pure.
The target buffer's variable `exec-path' and Eshell path are cleared before
the derivation's inputs are added."
  :type 'boolean
  :group 'nix)

(defcustom nix-shell-auto-realise t
  "When non-nil, realise input store paths that are not yet built.
Missing paths are built with \"nix-store --realise\" before their
/bin directories are added to the path."
  :type 'boolean
  :group 'nix)

;;; Pure core over a parsed derivation

;; "nix derivation show" returns an alist keyed by drv path; each value is
;; the derivation, whose `env' key holds the build environment.  These
;; helpers take that single-derivation alist (the cdr of the sole entry)
;; and never run a process.

(defun nix-shell--derivation (parsed)
  "Return the single derivation alist from PARSED.
PARSED is the alist decoded from \"nix derivation show\", keyed by
drv path.  The sole value is returned."
  (cdar parsed))

(defun nix-shell--env (drv)
  "Return the build environment alist of derivation DRV."
  (alist-get 'env drv))

(defun nix-shell--inputs (drv)
  "Return the input store paths configured for derivation DRV.
The values of every `nix-shell-inputs' key in DRV's environment
are split on whitespace and concatenated; empty entries drop out."
  (let ((env (nix-shell--env drv)))
    (seq-remove #'string-empty-p
                (mapcan (lambda (key)
                          (split-string (or (alist-get key env) "")))
                        nix-shell-inputs))))

(defun nix-shell--exec-path (paths)
  "Return the existing bin directories under store PATHS.
Each path contributes its \"bin\" subdirectory when that directory
exists."
  (seq-filter #'file-directory-p
              (mapcar (lambda (path) (expand-file-name "bin" path)) paths)))

(defun nix-shell--path-string (bins base)
  "Join BINS and BASE into a colon-separated PATH string.
BINS is a list of directories; BASE is the existing PATH string,
which is appended unless it is empty."
  (string-join (if (or (null base) (string-empty-p base))
                   bins
                 (append bins (list base)))
               path-separator))

(defun nix-shell--ld-library-path (drv)
  "Return the LD_LIBRARY_PATH set by DRV, or nil.
`mkShell' derivations set this variable directly in the
environment; other derivations leave it unset."
  (let ((value (alist-get 'LD_LIBRARY_PATH (nix-shell--env drv))))
    (and value (not (string-empty-p value)) value)))

(defun nix-shell--process-environment (drv bins &optional base clear)
  "Return the process environment for DRV with BINS on PATH.
BASE is the process environment list to extend, defaulting to the
current `process-environment'.  When CLEAR is non-nil BASE is
dropped and a fresh, empty environment is built, matching
nix-shell --pure.  The PATH entry is rebuilt from BINS ahead of the
base PATH; any LD_LIBRARY_PATH set by DRV is prepended to the base
value."
  (let* ((base (if clear nil (or base process-environment)))
         (path (nix-shell--path-string bins (nix-shell--base-var base "PATH")))
         (ld (nix-shell--ld-library-path drv))
         (env (cons (concat "PATH=" path) base)))
    (if ld
        (cons (nix-shell--ld-entry ld (nix-shell--base-var base "LD_LIBRARY_PATH"))
              env)
      env)))

(defun nix-shell--base-var (base name)
  "Return the value of variable NAME in environment list BASE, or nil.
BASE is read as `process-environment'; a nil BASE is an empty
environment, so no ambient value leaks in."
  (let ((process-environment base))
    (getenv name)))

(defun nix-shell--ld-entry (ld current)
  "Return an LD_LIBRARY_PATH entry putting LD ahead of CURRENT.
CURRENT is the existing LD_LIBRARY_PATH value, or nil."
  (if (and current (not (string-empty-p current)))
      (format "LD_LIBRARY_PATH=%s:%s" ld current)
    (concat "LD_LIBRARY_PATH=" ld)))

;;; Applying an environment to a buffer

(defun nix-shell--realise (paths)
  "Realise any of store PATHS that are not yet built.
Only runs when `nix-shell-auto-realise' is non-nil.  Missing paths
are built with \"nix-store --realise\"; a build failure signals."
  (when nix-shell-auto-realise
    (dolist (path paths)
      (unless (file-directory-p path)
        (nix--check (nix--call nix-store-executable (list "--realise" path))
                    "nix-store --realise")))))

(defun nix-shell--apply (buffer parsed)
  "Apply the environment of derivation PARSED to BUFFER.
PARSED is the alist from \"nix derivation show\".  The buffer's
variable `exec-path', `process-environment' and Eshell path are set
buffer-locally from a copy, never mutating the global values.  When
`nix-shell-auto-realise' is set, missing inputs are built first."
  (let* ((drv (nix-shell--derivation parsed))
         (inputs (nix-shell--inputs drv))
         (bins (progn (nix-shell--realise inputs)
                      (nix-shell--exec-path inputs))))
    (with-current-buffer buffer
      (let ((clear nix-shell-clear-environment))
        (setq-local exec-path
                    (append bins (unless clear (copy-sequence exec-path))))
        (setq-local process-environment
                    (nix-shell--process-environment
                     drv bins (copy-sequence process-environment) clear))
        (nix-shell--set-eshell-path bins clear)))))

(defun nix-shell--set-eshell-path (bins clear)
  "Set the buffer-local Eshell path from BINS.
CLEAR drops the existing entries.  Emacs 29+ carries the path in
`eshell-path-env-list'; the string `eshell-path-env' is kept in
sync for older code.  Both are only touched when already bound so a
non-Eshell buffer is left alone."
  (when (boundp 'eshell-path-env-list)
    (setq-local eshell-path-env-list
                (append bins (unless clear eshell-path-env-list))))
  (when (boundp 'eshell-path-env)
    (setq-local eshell-path-env
                (nix-shell--path-string
                 bins (unless clear eshell-path-env)))))

;;; Instantiation edges

(defun nix-shell--read-file ()
  "Return a Nix file, preferring `nix-file' then the working directory."
  (or (bound-and-true-p nix-file)
      (seq-find #'file-exists-p '("shell.nix" "default.nix"))
      (read-file-name "Nix file: " nil "<nixpkgs>")))

(defun nix-shell--read-attr ()
  "Read a Nix attribute, preferring `nix-attr', nil when empty."
  (or (bound-and-true-p nix-attr)
      (let ((attr (read-string "Nix attribute: ")))
        (and (not (string-empty-p attr)) attr))))

;;;###autoload
(defun nix-shell (file &optional attr)
  "Apply the shell environment of Nix FILE to the current buffer.
ATTR, when non-nil, selects an attribute of FILE.  FILE is
instantiated asynchronously; the derivation's inputs are then added
to the buffer-local variable `exec-path' and `process-environment'."
  (interactive (list (nix-shell--read-file) (nix-shell--read-attr)))
  (let ((buffer (current-buffer)))
    (nix-instantiate-async
     (lambda (drv)
       (when (buffer-live-p buffer)
         (nix-shell--apply buffer (nix--derivation-show drv))))
     file attr)))

;;;###autoload
(defun nix-shell-with-packages (packages &optional pkgs-file)
  "Apply a shell environment built from PACKAGES to the current buffer.
PACKAGES is a list of attribute names.  PKGS-FILE is the package
set to pull them from, defaulting to \"<nixpkgs>\"."
  (interactive (list (split-string (read-string "Packages: "))))
  (nix-shell (nix-shell--packages-file packages pkgs-file)))

(defun nix-shell--packages-file (packages &optional pkgs-file)
  "Write a temp Nix file pulling PACKAGES from PKGS-FILE.
PKGS-FILE defaults to \"<nixpkgs>\".  Return the file name."
  (let ((file (make-temp-file "nix-shell" nil ".nix"))
        (source (or pkgs-file "<nixpkgs>")))
    (with-temp-file file
      (insert (format "with import %s { };\n" source))
      (insert "runCommandCC \"shell\" {\n")
      (insert "  nativeBuildInputs = [\n")
      (dolist (package packages)
        (insert (format "    %s\n" package)))
      (insert "  ];\n} \"\"\n"))
    file))

;;; Eshell sessions

(defun nix-shell--eshell-buffer (parse-derivation)
  "Pop to a fresh Eshell buffer with PARSE-DERIVATION applied.
PARSE-DERIVATION is a thunk returning the parsed derivation.  The
new buffer starts a pure environment before the derivation's inputs
are added, matching nix-shell --pure.  The clear flag is let-bound
around the application because `eshell-mode' kills local variables."
  (let ((buffer (generate-new-buffer "*nix-eshell*")))
    (pop-to-buffer-same-window buffer)
    (require 'eshell)
    (eshell-mode)
    (let ((nix-shell-clear-environment t))
      (nix-shell--apply buffer (funcall parse-derivation)))
    buffer))

;;;###autoload
(defun nix-eshell (file &optional attr)
  "Open an Eshell whose environment is that of Nix FILE.
ATTR, when non-nil, selects an attribute of FILE.  The derivation
is instantiated synchronously so the environment is ready before
the shell prompt appears."
  (interactive (list (nix-shell--read-file) (nix-shell--read-attr)))
  (nix-shell--eshell-buffer
   (lambda () (nix-instantiate file attr t))))

;;;###autoload
(defun nix-eshell-with-packages (packages &optional pkgs-file)
  "Open an Eshell with a shell environment built from PACKAGES.
PKGS-FILE is the package set, defaulting to \"<nixpkgs>\"."
  (interactive (list (split-string (read-string "Packages: "))))
  (let ((file (nix-shell--packages-file packages pkgs-file)))
    (nix-shell--eshell-buffer
     (lambda () (nix-instantiate file nil t)))))

;;; Phase runners

;; The old module ran genericBuild phases through nix-shell --run.  Each
;; phase resolves to the same shell snippet: run the named *Phase, falling
;; back to eval-ing the phase function when the variable is empty.

(defun nix-shell--phase-script (phase)
  "Return the shell snippet running genericBuild PHASE."
  (format "if [ -z \"$%sPhase\" ]; then eval %sPhase; else eval \"$%sPhase\"; fi"
          phase phase phase))

(defun nix-shell--phase-args (phase file attr)
  "Return the nix-shell argument list running PHASE on FILE and ATTR."
  (append (list (nix--expand-file file))
          (and attr (list "-A" attr))
          (list "--run" (nix-shell--phase-script phase))))

(defun nix-shell--run-phase (phase file attr)
  "Run genericBuild PHASE on FILE and ATTR in a compilation buffer.
The nix-shell invocation is quoted into a shell command so the
compilation buffer shows a copy-pastable line."
  (let ((command (mapconcat #'shell-quote-argument
                            (cons nix-shell-executable
                                  (nix-shell--phase-args phase file attr))
                            " ")))
    (compilation-start command nil
                       (lambda (_mode) (format "*nix-shell %s*" phase)))))

;;;###autoload
(defun nix-shell-unpack (file &optional attr)
  "Run the unpackPhase of FILE, selecting ATTR when non-nil."
  (interactive (list (nix-shell--read-file) (nix-shell--read-attr)))
  (nix-shell--run-phase "unpack" file attr))

;;;###autoload
(defun nix-shell-configure (file &optional attr)
  "Run the configurePhase of FILE, selecting ATTR when non-nil."
  (interactive (list (nix-shell--read-file) (nix-shell--read-attr)))
  (nix-shell--run-phase "configure" file attr))

;;;###autoload
(defun nix-shell-build (file &optional attr)
  "Run the buildPhase of FILE, selecting ATTR when non-nil."
  (interactive (list (nix-shell--read-file) (nix-shell--read-attr)))
  (nix-shell--run-phase "build" file attr))

;;; Eshell nix command

;; Following NixOS/nix-mode PR #202: inside Eshell, "nix develop" and
;; "nix shell ..." (with no trailing "--command") normally spawn a
;; subshell, which is useless in Eshell.  The integration reruns them as
;; "... --command sh -c export", parses the resulting environment and
;; applies it to the running Eshell session, so the developer environment
;; lands in the shell they are already using.  Every other nix subcommand
;; falls through to the real binary.
;;
;; The interception is a global opt-in: `nix-eshell-integration-mode'
;; installs a `eshell/nix' alias, which Eshell resolves automatically when
;; a "nix" command word is entered, and removes it on disable.  This keeps
;; the plumbing out of the way for users who do not want it.

;; Variables the export dump carries that must not be forced onto the
;; session: shell bookkeeping that is meaningless outside the capture sh.
(defconst nix-shell--export-blocklist
  '("PWD" "SHLVL" "_" "OLDPWD" "SHELL")
  "Environment variables skipped when applying captured exports.")

(defun nix-shell--parse-exports (output)
  "Parse OUTPUT of \"sh -c export\" into an alist of (VAR . VALUE).
OUTPUT is a run of \"export VAR=\\\"VALUE\\\"\" lines; the value is
double-quoted with backslash-escaped inner quotes and backslashes.
Blocklisted variables (`nix-shell--export-blocklist') are dropped."
  (seq-keep #'nix-shell--parse-export-line (split-string output "\n")))

(defun nix-shell--parse-export-line (line)
  "Parse one export LINE into a (VAR . VALUE) cons, or nil.
Return nil for lines that are not \"export VAR=...\" or whose
variable is blocklisted."
  (and (string-match
        (rx bos (* space) "export" (+ space)
            (group (any "A-Za-z_") (* (any "A-Za-z0-9_"))) "=" (group (* nonl)))
        line)
       (let ((var (match-string 1 line)))
         (unless (member var nix-shell--export-blocklist)
           (cons var (nix-shell--unquote (match-string 2 line)))))))

(defun nix-shell--unquote (value)
  "Strip the shell double quotes and escapes from VALUE.
An unquoted VALUE is returned unchanged; a double-quoted one has
its quotes removed and its \\\" and \\\\ escapes resolved."
  (if (and (> (length value) 1)
           (string-prefix-p "\"" value)
           (string-suffix-p "\"" value))
      (replace-regexp-in-string
       (rx "\\" (group (any "\"\\`$")))
       "\\1" (substring value 1 -1))
    value))

(defun nix-shell--capture-args (args)
  "Return the argv capturing the environment of \"nix ARGS\".
ARGS is the argument list after \"nix\".  The subcommand is rerun
with \"--command sh -c export\" appended so its environment prints
as export lines."
  (append (list nix-executable) args
          (list "--command" "sh" "-c" "export")))

(defun nix-shell--apply-exports (exports)
  "Apply EXPORTS, an alist of (VAR . VALUE), to the current buffer.
Every variable is set in a buffer-local copy of
`process-environment'; PATH additionally refreshes the Eshell
path."
  (setq-local process-environment (copy-sequence process-environment))
  (pcase-dolist (`(,var . ,value) exports)
    (setenv var value))
  (let ((path (assoc "PATH" exports)))
    (when path
      (nix-shell--sync-eshell-path (cdr path)))))

(defun nix-shell--sync-eshell-path (path)
  "Point the buffer-local Eshell path variables at PATH."
  (when (boundp 'eshell-path-env-list)
    (setq-local eshell-path-env-list
                (split-string path path-separator)))
  (when (boundp 'eshell-path-env)
    (setq-local eshell-path-env path)))

(defun nix-shell--eshell-intercept-p (args)
  "Return non-nil when \"nix ARGS\" should be captured, not run.
Only \"nix develop\" and \"nix shell\" without an explicit
\"--command\" are captured; anything else runs the real binary."
  (and (member (car args) '("develop" "shell"))
       (not (member "--command" args))))

(defun nix-shell--eshell-nix (&rest args)
  "Eshell \"nix\" command with developer-environment interception.
ARGS is the argument list after \"nix\".
For \"nix develop\" and \"nix shell ...\" (with no \"--command\"),
capture the environment via \"--command sh -c export\" and apply it
to the running Eshell session.  Every other invocation falls
through to the real \"nix\" binary.  The capture is synchronous and
may block while Nix evaluates.

Installed as `eshell/nix' by `nix-eshell-integration-mode', which
is how Eshell resolves a \"nix\" command word to this function."
  (let ((args (eshell-stringify-list (flatten-tree args))))
    (if (nix-shell--eshell-intercept-p args)
        (nix-shell--eshell-load-env args)
      (throw 'eshell-replace-command
             (eshell-parse-command (concat "*" nix-executable) args)))))

(defun nix-shell--eshell-load-env (args)
  "Capture and apply the environment of \"nix ARGS\" to the session."
  (message "nix: loading environment ...")
  (let ((result (nix--call nix-executable (cdr (nix-shell--capture-args args)))))
    (nix-shell--apply-exports
     (nix-shell--parse-exports (nix--check result "nix develop")))
    (message "nix: environment loaded")))

;;;###autoload
(define-minor-mode nix-eshell-integration-mode
  "Toggle Eshell interception of \"nix develop\" and \"nix shell\".
When enabled, running those commands in Eshell loads the developer
environment into the current session instead of spawning a
subshell.  This is a global switch that installs the `eshell/nix'
command -- which Eshell resolves automatically for a \"nix\"
command word -- and removes it on disable."
  :global t
  :group 'nix
  (if nix-eshell-integration-mode
      (progn
        (require 'esh-cmd)
        (defalias 'eshell/nix #'nix-shell--eshell-nix))
    (when (eq (symbol-function 'eshell/nix) #'nix-shell--eshell-nix)
      (fmakunbound 'eshell/nix))))

(provide 'nix-shell)
;;; nix-shell.el ends here
