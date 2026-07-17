;;; nix-core.el --- Process layer for nix-mode  -*- lexical-binding: t; -*-

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

;; Bottom of the nix-mode dependency graph.  Provides shared
;; customization (the `nix' group and executable paths) and the process
;; layer every feature module builds on.
;;
;; The process layer is deliberately small: only `nix--call' and
;; `nix--start' touch the outside world.  Everything else is a pure
;; transformation over the result plist `(:exit CODE :stdout STRING
;; :stderr STRING)', so callers compose checks, JSON parsing and line
;; splitting without re-running processes.

;;; Code:

(require 'json)
(require 'pcomplete)
(require 'subr-x)

;;; Customization

(defgroup nix nil
  "Nix language and tooling support."
  :prefix "nix-"
  :group 'languages)

(defcustom nix-executable "nix"
  "Location of the \"nix\" executable."
  :type 'string)

(defcustom nix-build-executable "nix-build"
  "Location of the \"nix-build\" executable."
  :type 'string)

(defcustom nix-instantiate-executable "nix-instantiate"
  "Location of the \"nix-instantiate\" executable."
  :type 'string)

(defcustom nix-store-executable "nix-store"
  "Location of the \"nix-store\" executable."
  :type 'string)

(defcustom nix-shell-executable "nix-shell"
  "Location of the \"nix-shell\" executable."
  :type 'string)

(defcustom nix-store-dir "/nix/store"
  "Nix store directory."
  :type 'directory)

(defcustom nix-state-dir "/nix/var"
  "Nix state directory."
  :type 'directory)

;;; Process layer

;; Both effect functions return a result plist of the shape
;; `(:exit CODE :stdout STRING :stderr STRING)'.  Keeping the shape
;; identical between the sync and async paths lets the pure helpers below
;; work on either without knowing which one produced the result.

(defun nix--call (program args)
  "Run PROGRAM with ARGS synchronously and return a result plist.
ARGS is a list of string arguments.  The plist has the shape
\(:exit CODE :stdout STRING :stderr STRING)."
  (let ((stderr-file (make-temp-file "nix--call-stderr")))
    (unwind-protect
        (with-temp-buffer
          (let ((exit (apply #'call-process program nil
                             (list (current-buffer) stderr-file)
                             nil args)))
            (list :exit exit
                  :stdout (buffer-string)
                  :stderr (nix--file-string stderr-file))))
      (delete-file stderr-file))))

(defun nix--file-string (file)
  "Return the contents of FILE as a string."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun nix--start (program args callback)
  "Run PROGRAM with ARGS asynchronously and call CALLBACK on exit.
ARGS is a list of string arguments.  CALLBACK receives one
argument, a result plist of the shape produced by `nix--call'."
  (let ((stdout (generate-new-buffer " *nix-stdout*"))
        (stderr (generate-new-buffer " *nix-stderr*"))
        (state (vector nil nil nil)))
    (condition-case err
        (let ((stderr-process
               (make-pipe-process
                :name "nix-stderr"
                :buffer stderr
                :noquery t
                :sentinel (lambda (_proc _event)
                            (nix--start-maybe-finish
                             state stdout stderr callback)))))
          (aset state 1 stderr-process)
          (aset state 0
                (make-process
                 :name (format "nix-%s" (file-name-nondirectory program))
                 :command (cons program args)
                 :buffer stdout
                 :stderr stderr-process
                 :noquery t
                 :sentinel (lambda (_proc _event)
                             (nix--start-maybe-finish
                              state stdout stderr callback))))
          (nix--start-maybe-finish state stdout stderr callback)
          (aref state 0))
      (error
       (nix--start-abort state stdout stderr)
       (signal (car err) (cdr err))))))

(defun nix--start-abort (state stdout stderr)
  "Clean up partial async STATE and output buffers STDOUT and STDERR."
  (dolist (process (list (aref state 0) (aref state 1)))
    (when (and process (process-live-p process))
      (delete-process process)))
  (dolist (buffer (list stdout stderr))
    (when (buffer-live-p buffer)
      (kill-buffer buffer))))

(defun nix--start-maybe-finish (state stdout stderr callback)
  "Finish an asynchronous call when both processes in STATE have exited.
STDOUT and STDERR hold their respective output.  Invoke CALLBACK
exactly once with the collected result."
  (let ((process (aref state 0))
        (stderr-process (aref state 1)))
    (when (and process stderr-process
               (not (process-live-p process))
               (not (process-live-p stderr-process))
               (not (aref state 2)))
      (aset state 2 t)
      (nix--start-finish process stdout stderr callback))))

(defun nix--start-finish (proc stdout stderr callback)
  "Collect PROC output from STDOUT and STDERR then invoke CALLBACK.
The result plist is built from the buffers, which are killed
before CALLBACK runs."
  (let ((result (list :exit (process-exit-status proc)
                      :stdout (nix--buffer-string stdout)
                      :stderr (nix--buffer-string stderr))))
    (kill-buffer stdout)
    (when (buffer-live-p stderr)
      (kill-buffer stderr))
    (funcall callback result)))

(defun nix--buffer-string (buffer)
  "Return the contents of BUFFER, or an empty string if it is dead."
  (if (buffer-live-p buffer)
      (with-current-buffer buffer (buffer-string))
    ""))

(defun nix--check (result &optional context)
  "Return the :stdout of RESULT when it exited successfully.
Signal an error naming CONTEXT and the captured stderr otherwise.
CONTEXT is a short string describing the operation."
  (if (eq (plist-get result :exit) 0)
      (plist-get result :stdout)
    (error "%s failed: %s"
           (or context "nix")
           (string-trim (plist-get result :stderr)))))

(defun nix--result-json (result &optional context)
  "Parse the checked :stdout of RESULT as JSON.
CONTEXT is passed to `nix--check'.  Objects are decoded as alists
so downstream code can use `alist-get' and `let-alist'."
  (json-parse-string (nix--check result context)
                     :object-type 'alist
                     :array-type 'list))

(defun nix--result-lines (result &optional context)
  "Split the checked :stdout of RESULT into non-empty lines.
CONTEXT is passed to `nix--check'."
  (seq-remove #'string-empty-p
              (split-string (nix--check result context) "\n")))

(defun nix--call-json (program args &optional context)
  "Run PROGRAM with ARGS synchronously and parse the output as JSON.
CONTEXT is passed to `nix--check'."
  (nix--result-json (nix--call program args) context))

(defun nix--call-lines (program args &optional context)
  "Run PROGRAM with ARGS synchronously and return output lines.
CONTEXT is passed to `nix--check'."
  (nix--result-lines (nix--call program args) context))

;;; Version and system detection

(defvar nix--version-cache nil
  "Cached output of `nix --version', or nil if not yet queried.")

(defun nix--fetch-version ()
  "Query and return the installed Nix version string.
Runs the process every call; `nix-version' handles caching."
  (string-trim
   (nix--check (nix--call nix-executable '("--version")) "nix --version")))

;;;###autoload
(defun nix-version ()
  "Return and display the installed Nix version string."
  (interactive)
  (let ((version (or nix--version-cache
                     (setq nix--version-cache (nix--fetch-version)))))
    (when (called-interactively-p 'interactive)
      (message "%s" version))
    version))

(defvar nix--flakes-cache 'unknown
  "Cached flakes availability, `unknown' until first queried.")

(defun nix-has-flakes-p ()
  "Return non-nil when the flakes experimental feature is enabled."
  (if (eq nix--flakes-cache 'unknown)
      (setq nix--flakes-cache (nix--query-flakes))
    nix--flakes-cache))

(defun nix--query-flakes ()
  "Return non-nil when \"flakes\" is in the experimental features."
  (let-alist (nix-show-config)
    (and (member "flakes" .experimental-features.value) t)))

(defun nix--unquote (string)
  "Return STRING without surrounding whitespace and double quotes.
Nix evaluation output prints strings quoted and newline-terminated;
this undoes both layers."
  (string-trim (string-trim string) "\"" "\""))

;;;###autoload
(defun nix-system ()
  "Return and display the current Nix system tuple.
Uses \"nix-instantiate --eval\" so it works without flakes on any
Nix 2.4 or later."
  (interactive)
  (let ((system (nix--unquote
                 (nix--check
                  (nix--call nix-instantiate-executable
                             '("--eval" "-E" "builtins.currentSystem"))
                  "nix-instantiate --eval"))))
    (when (called-interactively-p 'interactive)
      (message "%s" system))
    system))

;;;###autoload
(defun nix-show-config ()
  "Return the Nix configuration parsed from \"nix config show --json\".
When called interactively, display it in a help buffer instead."
  (interactive)
  (let ((config (nix--call-json nix-executable
                                '("config" "show" "--json")
                                "nix config show")))
    (if (called-interactively-p 'interactive)
        (nix--display-config config)
      config)))

(defun nix--display-config (config)
  "Render CONFIG, an alist of settings, into a help buffer."
  (with-help-window "*Nix Config*"
    (with-current-buffer standard-output
      (dolist (setting config)
        (let-alist (cdr setting)
          (insert (format "%s = %s\n" (car setting) .value)))))))

;;; Instantiation

(defun nix-instantiate (file &optional attribute parse)
  "Instantiate FILE and return its derivation path.
ATTRIBUTE, when non-nil, selects an attribute of FILE.  With PARSE
non-nil return the parsed derivation from \"nix derivation show\"
rather than the raw path."
  (interactive (list (read-file-name "Nix file: ") nil t))
  (let* ((args (nix--instantiate-args file attribute))
         (drv (string-trim
               (nix--check (nix--call nix-instantiate-executable args)
                           "nix-instantiate")))
         (value (if parse (nix--derivation-show drv) drv)))
    (when (called-interactively-p 'interactive)
      (message "%s" value))
    value))

(defun nix--expand-file (file)
  "Expand FILE unless it is an angle-bracket path like \"<nixpkgs>\".
Angle-bracket paths are Nix search-path lookups and must reach the
command line verbatim."
  (if (string-prefix-p "<" file) file (expand-file-name file)))

(defun nix--instantiate-args (file attribute)
  "Build the nix-instantiate argument list for FILE and ATTRIBUTE."
  (append (list (nix--expand-file file))
          (and attribute (list "-A" attribute))))

(defun nix--derivation-show (drv)
  "Return the parsed derivation for DRV via \"nix derivation show\"."
  (nix--call-json nix-executable
                  (list "derivation" "show" drv)
                  "nix derivation show"))

(defvar nix--instantiate-registry (make-hash-table :test #'equal)
  "Map of pending instantiation key -> list of callbacks.
Concurrent async requests for the same file and attribute share a
single process; each caller's callback is stored under the key.")

(defun nix--instantiate-key (file attribute)
  "Return the registry key for FILE and ATTRIBUTE."
  (let ((path (nix--expand-file file)))
    (if attribute (concat path "!" attribute) path)))

(defun nix--instantiate-register (key callback &optional finally)
  "Register CALLBACK and optional FINALLY function under KEY.
Return non-nil when a process for KEY is already running, meaning
the caller should not start another."
  (let ((pending (gethash key nix--instantiate-registry)))
    (puthash key (cons (cons callback finally) pending)
             nix--instantiate-registry)
    (and pending t)))

(defun nix--instantiate-dispatch (key value)
  "Invoke and clear all callbacks registered under KEY with VALUE."
  (let ((callbacks (gethash key nix--instantiate-registry)))
    (remhash key nix--instantiate-registry)
    (dolist (entry callbacks)
      (unwind-protect
          (funcall (car entry) value)
        (when (cdr entry)
          (funcall (cdr entry)))))))

(defun nix--instantiate-fail (key)
  "Clear KEY and invoke its registered finalizers."
  (let ((callbacks (gethash key nix--instantiate-registry)))
    (remhash key nix--instantiate-registry)
    (dolist (entry callbacks)
      (when (cdr entry)
        (funcall (cdr entry))))))

(defun nix--instantiate-sentinel (key result)
  "Dispatch KEY callbacks with the drv path parsed from RESULT.
On a nonzero exit, clear KEY from the registry without invoking
its callbacks and report the failure with `message', since a
process sentinel has no caller to signal to."
  (if (eq (plist-get result :exit) 0)
      (nix--instantiate-dispatch key (string-trim (plist-get result :stdout)))
    (nix--instantiate-fail key)
    (message "nix-instantiate failed: %s"
             (string-trim (plist-get result :stderr)))))

(defun nix-instantiate-async (callback file &optional attribute finally)
  "Instantiate FILE asynchronously and pass the drv path to CALLBACK.
ATTRIBUTE, when non-nil, selects an attribute of FILE.  Concurrent
requests for the same FILE and ATTRIBUTE share one process.  On a
failed instantiation the shared registry entry is cleared, CALLBACK
is not invoked, and the error is reported with `message'.  FINALLY,
when non-nil, is called after success or failure."
  (let ((key (nix--instantiate-key file attribute)))
    (unless (nix--instantiate-register key callback finally)
      (condition-case err
          (nix--start nix-instantiate-executable
                      (nix--instantiate-args file attribute)
                      (lambda (result)
                        (nix--instantiate-sentinel key result)))
        (error
         (nix--instantiate-fail key)
         (signal (car err) (cdr err)))))))

;;; Command completion

;; Nix 2.4+ ships native completion via the NIX_GET_COMPLETIONS
;; environment variable, so the large static command and option lists the
;; old nix.el carried are gone.  `nix' prints a mode line ("normal",
;; "filenames" or "attrs") followed by tab-separated
;; "completion\tdescription" rows.

;;;###autoload
(defun pcomplete/nix ()
  "Completion for the \"nix\" command via native NIX_GET_COMPLETIONS."
  (let* ((parsed (nix--native-completions pcomplete-args))
         (mode (car parsed))
         (candidates (cdr parsed)))
    (dolist (_ (cddr pcomplete-args))
      (pcomplete-here))
    ;; In "filenames" mode Nix wants a path (e.g. `nix build ./dir'), so
    ;; add file completion alongside whatever candidates it offered.
    (if (eq mode 'filenames)
        (while (pcomplete-here (append candidates (pcomplete-entries))))
      (pcomplete-here candidates nil t))))

(defun nix--native-completions (args)
  "Return native completions for ARGS, the current `pcomplete-args'.
ARGS starts with the command word; its length drives the
NIX_GET_COMPLETIONS index Nix expects.  The return value is the
cons produced by `nix--parse-completions'."
  (let ((process-environment
         (cons (format "NIX_GET_COMPLETIONS=%d" (1- (length args)))
               process-environment)))
    (nix--parse-completions
     (plist-get (nix--call nix-executable (cdr args)) :stdout))))

(defun nix--parse-completions (output)
  "Parse OUTPUT from a NIX_GET_COMPLETIONS run into `(MODE . CANDIDATES)'.
MODE is the completion mode symbol Nix emits on the first line,
one of `normal', `filenames' or `attrs' (nil for empty OUTPUT).
CANDIDATES is the list of candidate strings taken from the first
tab-separated field of each remaining non-empty line."
  (pcase (split-string output "\n")
    (`(,mode . ,rows)
     (cons (and (not (string-empty-p mode)) (intern mode))
           (thread-last rows
                        (seq-remove #'string-empty-p)
                        (mapcar (lambda (row)
                                  (car (split-string row "\t")))))))))

(provide 'nix-core)
;;; nix-core.el ends here
