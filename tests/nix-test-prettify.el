;;; nix-test-prettify.el --- Tests for nix-prettify  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Thanos Apollo

;;; Commentary:

;; Tests for `nix-prettify-mode': store hashes are composed to
;; `nix-prettify-char' on enable and decomposed on disable.

;;; Code:

(require 'ert)
(require 'nix-prettify)

(defconst nix-prettify-test--path
  "/nix/store/72f54nfp6g1hz873w8z3gfcah0h4nl9p-foo-0.1"
  "A sample store path whose hash should be prettified.")

(defmacro nix-prettify-test--with-buffer (content &rest body)
  "Run BODY in a font-locking temp buffer holding CONTENT."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (fundamental-mode)
     (setq font-lock-defaults '(nil))
     (insert ,content)
     ,@body))

(defun nix-prettify-test--composition-at (needle)
  "Return the `composition' property at the start of NEEDLE, or nil."
  (goto-char (point-min))
  (search-forward needle)
  (get-text-property (match-beginning 0) 'composition))

(ert-deftest nix-prettify-test-composes-hash-on-enable ()
  "Enabling the mode composes the store hash region."
  (nix-prettify-test--with-buffer nix-prettify-test--path
				  (nix-prettify-mode)
				  (font-lock-ensure)
				  (should (nix-prettify-test--composition-at "72f54nfp"))))

(ert-deftest nix-prettify-test-decomposes-hash-on-disable ()
  "Disabling the mode removes the composition."
  (nix-prettify-test--with-buffer nix-prettify-test--path
				  (nix-prettify-mode)
				  (font-lock-ensure)
				  (should (nix-prettify-test--composition-at "72f54nfp"))
				  (nix-prettify-mode -1)
				  (font-lock-ensure)
				  (should-not (nix-prettify-test--composition-at "72f54nfp"))))

(ert-deftest nix-prettify-test-disable-preserves-foreign-composition ()
  "Disabling the mode removes only its own hash compositions."
  (nix-prettify-test--with-buffer
      (concat "foreign " nix-prettify-test--path)
    (compose-region (point-min) (+ (point-min) 7) ?F)
    (nix-prettify-mode)
    (font-lock-ensure)
    (should (get-text-property (point-min) 'composition))
    (should (nix-prettify-test--composition-at "72f54nfp"))
    (nix-prettify-mode -1)
    (font-lock-ensure)
    (should (get-text-property (point-min) 'composition))
    (should-not (nix-prettify-test--composition-at "72f54nfp"))))

(ert-deftest nix-prettify-test-does-not-replace-foreign-hash-composition ()
  "The mode leaves a pre-existing composition over a store hash untouched."
  (nix-prettify-test--with-buffer nix-prettify-test--path
    (goto-char (point-min))
    (search-forward "72f54nfp")
    (let ((beg (- (point) 8)))
      (compose-region beg (point) ?F)
      (let ((foreign (get-text-property beg 'composition)))
        (nix-prettify-mode)
        (font-lock-ensure)
        (should (equal foreign (get-text-property beg 'composition)))
        (nix-prettify-mode -1)
        (font-lock-ensure)
        (should (equal foreign (get-text-property beg 'composition)))))))

(ert-deftest nix-prettify-test-disable-preserves-replacement-composition ()
  "Disabling preserves a foreign composition that replaced the owned one."
  (nix-prettify-test--with-buffer nix-prettify-test--path
    (nix-prettify-mode)
    (font-lock-ensure)
    (goto-char (point-min))
    (search-forward "72f54nfp")
    (let ((beg (- (point) 8)))
      (compose-region beg (point) ?F)
      (let ((foreign (get-text-property beg 'composition)))
        (nix-prettify-mode -1)
        (font-lock-ensure)
        (should (equal foreign (get-text-property beg 'composition)))))))

(ert-deftest nix-prettify-test-leaves-plain-text-alone ()
  "Text without a store path gets no composition."
  (nix-prettify-test--with-buffer "just some plain text here"
				  (nix-prettify-mode)
				  (font-lock-ensure)
				  (should-not (nix-prettify-test--composition-at "plain"))))

(ert-deftest nix-prettify-test-safe-p-honours-font-lock ()
  "A buffer with `font-lock-defaults' is a safe prettify target."
  (nix-prettify-test--with-buffer ""
				  (should (nix-prettify--safe-p)))
  (with-temp-buffer
    (fundamental-mode)
    (setq font-lock-defaults nil)
    (should-not (nix-prettify--safe-p))))

(provide 'nix-test-prettify)
;;; nix-test-prettify.el ends here
