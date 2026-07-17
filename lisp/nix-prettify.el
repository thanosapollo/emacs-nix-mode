;;; nix-prettify.el --- Prettify Nix store hashes  -*- lexical-binding: t; -*-

;; Copyright (C) 2014, 2015 Alex Kost <alezost@gmail.com>
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

;; Prettify the 32-character base32 hash in Nix store paths, so that
;; "/nix/store/72f54nfp6g1hz873w8z3gfcah0h4nl9p-foo-0.1" is displayed
;; as "/nix/store/…-foo-0.1" in the current buffer.
;;
;; Enable it per buffer with `nix-prettify-mode', or everywhere a buffer
;; can safely take extra font-lock keywords with `global-nix-prettify-mode'.
;;
;; The work is done entirely through font-lock: a keyword composes the
;; matched hash to `nix-prettify-char' on enable and the composition is
;; decomposed on disable.  This module depends on nothing beyond built-in
;; font-lock, so it stays a leaf in the nix-mode dependency graph.

;;; Code:

(require 'font-lock)

;;; Customization

(defcustom nix-prettify-char ?…
  "Character shown in place of a Nix store hash."
  :type 'character
  :group 'nix)

(defcustom nix-prettify-regexp
  ;; Store paths, nar and log URLs all carry the same hash:
  ;;   /nix/store/…-foo-0.1
  ;;   https://cache.nixos.org/nar/…
  ;;   https://hydra.nixos.org/log/…
  ;; The base32 alphabet omits "e", "o", "u" and "t"; see base32Chars in
  ;; the Nix sources.
  (rx "/" (or "store" "nar" "log") "/"
      (group (= 32 (any "0-9" "a-d" "f-n" "p-s" "v-z"))))
  "Regexp matching store paths to prettify.
Group `nix-prettify-regexp-group' is the hash replaced by
`nix-prettify-char'.  Disable `nix-prettify-mode' before changing
this, and adjust `nix-prettify-regexp-group' to match."
  :type 'regexp
  :group 'nix)

(defcustom nix-prettify-regexp-group 1
  "Regexp group of `nix-prettify-regexp' composed to `nix-prettify-char'."
  :type 'natnum
  :group 'nix)

(defcustom nix-prettify-special-modes
  '(nix-store-path-mode nix-search-mode ibuffer-mode)
  "Major modes where `global-nix-prettify-mode' prettifies anyway.
`global-nix-prettify-mode' skips buffers whose `font-lock-defaults'
is nil, since new font-lock keywords can break their highlighting.
Modes in this list, and modes derived from them, are treated as
safe exceptions."
  :type '(repeat symbol)
  :group 'nix)

;;; Composition

(defun nix-prettify--compose ()
  "Compose the matched hash to `nix-prettify-char'.
Called as a font-lock MATCH-HIGHLIGHT form; return nil so no face
property is added."
  (let ((beg (match-beginning nix-prettify-regexp-group))
        (end (match-end nix-prettify-regexp-group)))
    (unless (text-property-not-all beg end 'composition nil)
      (compose-region beg end nix-prettify-char 'decompose-region)
      (put-text-property beg end 'nix-prettify
                         (get-text-property beg 'composition))))
  nil)

(defun nix-prettify--keywords ()
  "Return the font-lock keywords composing store hashes."
  `((,nix-prettify-regexp
     (,nix-prettify-regexp-group (nix-prettify--compose)))))

(defun nix-prettify--decompose-buffer ()
  "Remove hash compositions owned by `nix-prettify-mode'."
  (with-silent-modifications
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (point-min))
        (while (< (point) (point-max))
          (if (get-text-property (point) 'nix-prettify)
              (let* ((beg (point))
                     (owned (get-text-property beg 'nix-prettify))
                     (current (get-text-property beg 'composition))
                     (owned-end (next-single-property-change
                                 beg 'nix-prettify nil (point-max)))
                     (current-end (next-single-property-change
                                   beg 'composition nil (point-max)))
                     (end (min owned-end current-end)))
                (when (equal owned current)
                  (remove-text-properties beg end '(composition nil)))
                (remove-text-properties beg end '(nix-prettify nil))
                (goto-char end))
            (goto-char (next-single-property-change
                        (point) 'nix-prettify nil (point-max)))))))))

;;; Minor modes

;;;###autoload
(define-minor-mode nix-prettify-mode
  "Toggle prettifying of Nix store hashes in the current buffer.
When enabled, the 32-character hash of every store path (see
`nix-prettify-regexp') is displayed as `nix-prettify-char'.

Enable it from a hook to prettify a class of buffers:

  (add-hook \\='shell-mode-hook \\='nix-prettify-mode)

See `global-nix-prettify-mode' to prettify everywhere it is safe."
  :lighter " …"
  (let ((keywords (nix-prettify--keywords)))
    (if nix-prettify-mode
        (font-lock-add-keywords nil keywords)
      (font-lock-remove-keywords nil keywords)
      (nix-prettify--decompose-buffer)))
  (font-lock-flush))

(defun nix-prettify--safe-p ()
  "Return non-nil when prettifying is safe in the current buffer.
Safe means the buffer font-locks, or its mode is one of
`nix-prettify-special-modes'."
  (or font-lock-defaults
      (apply #'derived-mode-p nix-prettify-special-modes)))

(defun nix-prettify--turn-on ()
  "Enable `nix-prettify-mode' when the current buffer can take it."
  (and (not nix-prettify-mode)
       (nix-prettify--safe-p)
       (nix-prettify-mode)))

;;;###autoload
(define-globalized-minor-mode global-nix-prettify-mode
  nix-prettify-mode nix-prettify--turn-on
  :group 'nix)

(provide 'nix-prettify)
;;; nix-prettify.el ends here
