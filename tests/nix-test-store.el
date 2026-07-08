;;; nix-test-store.el --- Tests for nix-store  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Thanos Apollo

;;; Commentary:

;; Pure and hermetic tests for the nix-store browser.  Nothing here
;; queries a real store: the render pipeline runs on a fixture plist, and
;; query-plist assembly stubs `nix--call' via `cl-letf'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'nix-store)

;;; Fixture

(defconst nix-store-test--path
  "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-foo-1.0"
  "Fake store path used as the subject of the fixture.")

(defconst nix-store-test--ref
  "/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-bar-2.0"
  "Fake store path used as a reference in the fixture.")

(defconst nix-store-test--out
  "/nix/store/dddddddddddddddddddddddddddddddd-foo-1.0-doc"
  "Fake store path used as an output in the fixture.")

(defun nix-store-test--data ()
  "Return a fixture query plist with fake store paths."
  (list :path nix-store-test--path
        :deriver "/nix/store/cccccccccccccccccccccccccccccccc-foo.drv"
        :derivers '("/nix/store/cccccccccccccccccccccccccccccccc-foo.drv")
        :hash "sha256:deadbeef"
        :size 12345
        :outputs (list nix-store-test--path nix-store-test--out)
        :references (list nix-store-test--path nix-store-test--ref)
        :referrers (list nix-store-test--ref)
        :requisites (list nix-store-test--path nix-store-test--ref)))

(defmacro nix-store-test--with-render (data &rest body)
  "Render DATA into a temp `nix-store-path-mode' buffer, then run BODY."
  (declare (indent 1))
  `(with-temp-buffer
     (nix-store-path-mode)
     (setq nix-store--current-path (plist-get ,data :path))
     (nix-store--render ,data)
     ,@body))

;;; Group 1: header block

(ert-deftest nix-store-test-header-lines-present ()
  (nix-store-test--with-render (nix-store-test--data)
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "^Path:" text))
      (should (string-match-p "^Status: *unrealised" text))
      (should (string-match-p "^Hash: *sha256:deadbeef" text))
      (should (string-match-p "^Size:" text)))))

(ert-deftest nix-store-test-size-humanized ()
  "Size renders via `file-size-human-readable', not as a raw number."
  (nix-store-test--with-render (nix-store-test--data)
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "Size: *12k" text))
      (should-not (string-match-p "12345" text)))))

;;; Group 2: sections and outline

(ert-deftest nix-store-test-section-headings-match-outline-regexp ()
  "Every rendered section title starts an outline heading."
  (nix-store-test--with-render (nix-store-test--data)
    (goto-char (point-min))
    (dolist (section nix-store-sections)
      (let ((title (nix-store--section-title section)))
	(goto-char (point-min))
	(when (re-search-forward (concat "^" (regexp-quote title)) nil t)
	  (beginning-of-line)
	  (should (looking-at-p outline-regexp)))))))

(ert-deftest nix-store-test-section-titles-capitalized ()
  (nix-store-test--with-render (nix-store-test--data)
    (goto-char (point-min))
    (should (re-search-forward "^Outputs (" nil t))
    (should (re-search-forward "^References (" nil t))
    (should (re-search-forward "^Requisites (" nil t))))

(ert-deftest nix-store-test-derivers-section-renders ()
  "The default section list includes derivers and they render."
  (nix-store-test--with-render (nix-store-test--data)
    (goto-char (point-min))
    (should (re-search-forward "^Derivers (1)" nil t))))

(ert-deftest nix-store-test-header-lines-are-not-headings ()
  "Header block lines must not match `outline-regexp'."
  (nix-store-test--with-render (nix-store-test--data)
    (dolist (label '("Path:" "Status:" "Hash:" "Size:"))
      (goto-char (point-min))
      (re-search-forward (concat "^" (regexp-quote label)))
      (beginning-of-line)
      (should-not (looking-at-p outline-regexp)))))

;;; Group 3: buttons

(ert-deftest nix-store-test-store-paths-are-buttons ()
  "Each rendered store path carries a `nix-store-path-button'."
  (nix-store-test--with-render (nix-store-test--data)
    (goto-char (point-min))
    (let (found)
      (while (re-search-forward (regexp-quote nix-store-test--ref) nil t)
	(let ((button (button-at (match-beginning 0))))
	  (should button)
	  (should (eq (button-type button) 'nix-store-path-button))
	  (setq found t)))
      (should found))))

(ert-deftest nix-store-test-header-path-is-button ()
  (nix-store-test--with-render (nix-store-test--data)
    (goto-char (point-min))
    (re-search-forward (regexp-quote nix-store-test--path))
    (should (button-at (match-beginning 0)))))

;;; Group 4: omit-self

(ert-deftest nix-store-test-omit-self-drops-path ()
  "With `nix-store-path-omit-self', the path is absent from sections."
  (let ((nix-store-path-omit-self t))
    (should (equal (list nix-store-test--ref)
                   (nix-store--section-paths (nix-store-test--data)
                                             'references)))))

(ert-deftest nix-store-test-omit-self-nil-keeps-path ()
  (let ((nix-store-path-omit-self nil))
    (should (equal (list nix-store-test--path nix-store-test--ref)
                   (nix-store--section-paths (nix-store-test--data)
                                             'references)))))

;;; Group 5: section customization

(ert-deftest nix-store-test-sections-reordered ()
  "Rendering follows the order of `nix-store-sections'."
  (let ((nix-store-sections '(referrers outputs)))
    (nix-store-test--with-render (nix-store-test--data)
      (goto-char (point-min))
      (let ((referrers (progn (re-search-forward "^Referrers") (point)))
	    (outputs (progn (re-search-forward "^Outputs") (point))))
	(should (< referrers outputs))))))

(ert-deftest nix-store-test-sections-dropped ()
  "Sections not in `nix-store-sections' are not rendered."
  (let ((nix-store-sections '(outputs)))
    (nix-store-test--with-render (nix-store-test--data)
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
	(should (string-match-p "^Outputs" text))
	(should-not (string-match-p "^References" text))
	(should-not (string-match-p "^Referrers" text))))))

;;; Group 6: query-plist assembly (nix--call stubbed)

(defun nix-store-test--stub-call (args)
  "Return a fixture result plist for a nix-store --query in ARGS.
ARGS is the argument list passed to `nix--call'."
  (let ((flag (nth 1 args)))
    (list :exit 0 :stderr ""
          :stdout
          (pcase flag
            ("--deriver" "/nix/store/cccccccccccccccccccccccccccccccc-foo.drv\n")
            ("--hash" "sha256:deadbeef\n")
            ("--size" "12345\n")
            ("--outputs" (concat nix-store-test--path "\n"))
            ("--references" (concat nix-store-test--path "\n"
                                    nix-store-test--ref "\n"))
            ("--referrers" (concat nix-store-test--ref "\n"))
            ("--requisites" (concat nix-store-test--path "\n"
                                    nix-store-test--ref "\n"))
            (_ "")))))

(ert-deftest nix-store-test-query-all-assembles-plist ()
  (cl-letf (((symbol-function 'nix--call)
             (lambda (_program args) (nix-store-test--stub-call args))))
	   (let ((data (nix-store--query-all nix-store-test--path)))
	     (should (equal nix-store-test--path (plist-get data :path)))
	     (should (equal 12345 (plist-get data :size)))
	     (should (equal "sha256:deadbeef" (plist-get data :hash)))
	     (should (equal (list nix-store-test--path nix-store-test--ref)
			    (plist-get data :references)))
	     (should (equal (list nix-store-test--ref)
			    (plist-get data :referrers))))))

(ert-deftest nix-store-test-deriver-unknown-normalized-to-nil ()
  "A deriver of \"unknown-deriver\" becomes nil."
  (cl-letf (((symbol-function 'nix--call)
             (lambda (_program _args)
               (list :exit 0 :stderr "" :stdout "unknown-deriver\n"))))
	   (should-not (nix-store--deriver nix-store-test--path))))

;;; Group 7: path at point

(ert-deftest nix-store-test-path-at-point-inside-store ()
  (with-temp-buffer
    (insert nix-store-test--path)
    (goto-char (+ (point-min) 20))
    (should (equal nix-store-test--path (nix-store--path-at-point)))))

(ert-deftest nix-store-test-path-at-point-outside-store-is-nil ()
  (with-temp-buffer
    (insert "/etc/passwd")
    (goto-char (+ (point-min) 3))
    (should-not (nix-store--path-at-point))))

(provide 'nix-test-store)
;;; nix-test-store.el ends here
