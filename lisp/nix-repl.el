;;; nix-repl.el --- Interactive Nix REPL  -*- lexical-binding: t; -*-

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

;; A comint front-end for "nix repl".  `nix-repl' pops to the shared
;; "*Nix-REPL*" buffer, starting the process when needed.
;;
;; Completion reuses the REPL's own readline tab-completion rather than a
;; static table: `nix-repl--fetch-candidates' sends "PREFIX\t\t" behind a
;; redirected process filter, then clears the edited line.  The raw echo
;; is handed to the pure `nix-repl--parse-candidates', which is the only
;; part that needs to understand readline's column listings, so it is the
;; unit-testable seam.  All process and buffer effects live in the small
;; edge helpers; the parser is a plain string -> list transform.

;;; Code:

(require 'comint)
(require 'nix-core)

;;; Customization

(defcustom nix-repl-executable-args '("repl")
  "Arguments passed to `nix-executable' to start the REPL."
  :type '(repeat string)
  :group 'nix)

(defcustom nix-repl-completion-output-timeout 1.0
  "Seconds to wait for readline completion output before giving up."
  :type 'number
  :group 'nix)

(defvar nix-repl-prompt-regexp "nix-repl> "
  "Regexp matching the \"nix repl\" prompt.")

(defvar nix-repl-buffer-name "*Nix-REPL*"
  "Name of the shared interactive REPL buffer.")

;;; History

(defun nix-repl--history-file ()
  "Return the path of the shared \"nix repl\" history file.
Reuses the XDG data location \"nix repl\" itself writes to, so an
existing history carries over."
  (let ((xdg (getenv "XDG_DATA_HOME")))
    (expand-file-name
     "nix/repl-history"
     (if (and xdg (not (string-empty-p xdg))) xdg "~/.local/share"))))

(defun nix-repl--save-input-ring ()
  "Persist the current buffer's comint input ring, ignoring errors.
Suitable for `kill-buffer-hook'; a missing history directory or an
unwritable file must not block killing the buffer."
  (ignore-errors (comint-write-input-ring)))

;;; Major mode

(define-derived-mode nix-repl-mode comint-mode "Nix-REPL"
  "Major mode for the interactive \"nix repl\".

\\{nix-repl-mode-map}"
  :interactive nil
  (setq-local comint-prompt-regexp nix-repl-prompt-regexp)
  (setq-local comint-prompt-read-only t)
  (setq-local comint-input-ring-file-name (nix-repl--history-file))
  (setq-local comint-input-ignoredups t)
  (comint-read-input-ring t)
  (add-hook 'kill-buffer-hook #'nix-repl--save-input-ring nil t)
  (add-hook 'completion-at-point-functions
            #'nix-repl-completion-at-point nil t))

(keymap-set nix-repl-mode-map "TAB" #'completion-at-point)

;;;###autoload
(defun nix-repl ()
  "Pop to the interactive Nix REPL, starting it when needed."
  (interactive)
  (pop-to-buffer (nix-repl--ensure-buffer)))

(defun nix-repl--ensure-buffer ()
  "Return the REPL buffer, starting its process when absent."
  (let ((buffer (get-buffer-create nix-repl-buffer-name)))
    (unless (comint-check-proc buffer)
      (apply #'make-comint-in-buffer
             "Nix-REPL" buffer nix-executable nil nix-repl-executable-args)
      (with-current-buffer buffer (nix-repl-mode)))
    buffer))

;;; Completion parsing (pure)

(defun nix-repl--parse-candidates (prefix output)
  "Return completion candidates for PREFIX parsed from readline OUTPUT.
OUTPUT is the raw echo produced by sending \"PREFIX\\t\\t\" to the
REPL.  Prompt tails, the echoed prefix and duplicates are dropped;
what remains are the attribute paths readline offered.  Returns nil
when the REPL had no completion (only the prefix echoed back)."
  (let* ((body (car (split-string output nix-repl-prompt-regexp)))
         (tokens (split-string body "[ \f\t\n\r\v]+" t))
         (matches (delete-dups
                   (seq-filter (lambda (token) (string-prefix-p prefix token))
                               tokens))))
    (unless (seq-every-p (lambda (candidate) (string= candidate prefix)) matches)
      (seq-remove (lambda (candidate) (string= candidate prefix)) matches))))

(defun nix-repl--attr-bounds ()
  "Return the (BEG . END) bounds of the attribute path at point, or nil.
An attribute path is a dotted identifier such as
\"builtins.fetchTarball\"."
  (save-excursion
    (let ((end (progn (skip-chars-forward "a-zA-Z0-9'_.-") (point)))
          (beg (progn (skip-chars-backward "a-zA-Z0-9'_.-") (point))))
      (and (< beg end) (cons beg end)))))

;;; Completion (effects at the edge)

(defmacro nix-repl--with-redirected-filter (process buffer &rest body)
  "Redirect PROCESS output into BUFFER for the duration of BODY.
PROCESS's original filter is restored afterwards even on error.
BODY runs with BUFFER current and its point at the end."
  (declare (indent 2) (debug (form form body)))
  (let ((saved (make-symbol "saved")))
    `(let ((,saved (process-filter ,process)))
       (set-process-filter
        ,process (lambda (_proc string)
                   (with-current-buffer ,buffer
                     (goto-char (point-max))
                     (insert string))))
       (unwind-protect
           (with-current-buffer ,buffer ,@body)
         (set-process-filter ,process ,saved)))))

(defun nix-repl--clear-input-string ()
  "Return readline controls that erase the current REPL line."
  "\C-a\C-k")

(defun nix-repl--fetch-candidates (process prefix)
  "Return completion candidates for PREFIX from the REPL PROCESS.
Sends \"PREFIX\\t\\t\" behind a redirected filter, waits for the
listing, then clears the edited line, leaving the prompt untouched."
  (let ((buffer (generate-new-buffer " *nix-repl-completions*")))
    (unwind-protect
        (nix-repl--with-redirected-filter process buffer
	  (process-send-string process (concat prefix "\t\t"))
	  (nix-repl--await-output process)
	  (process-send-string process (nix-repl--clear-input-string))
	  (nix-repl--parse-candidates prefix (buffer-string)))
      (kill-buffer buffer))))

(defun nix-repl--await-output (process)
  "Accept PROCESS output until it settles or the timeout elapses."
  (while (accept-process-output
          process nix-repl-completion-output-timeout)))

;;;###autoload
(defun nix-repl-completion-at-point ()
  "Completion-at-point for the Nix REPL using readline completion.
See `completion-at-point-functions'."
  (and-let* (((derived-mode-p 'nix-repl-mode))
             (process (get-buffer-process (current-buffer)))
             (bounds (nix-repl--attr-bounds)))
    (let ((prefix (buffer-substring-no-properties (car bounds) (cdr bounds))))
      (list (car bounds) (cdr bounds)
            (completion-table-with-cache
             (lambda (_input) (nix-repl--fetch-candidates process prefix)))
            :exclusive 'no))))

(provide 'nix-repl)
;;; nix-repl.el ends here
