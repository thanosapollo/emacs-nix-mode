;;; nix-test-core.el --- Tests for nix-core  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Thanos Apollo

;;; Commentary:

;; Pure and hermetic tests for the nix-core process layer.  No test here
;; requires the real nix binary or network access; process tests use
;; /bin/sh fixtures instead.

;;; Code:

(require 'ert)
(require 'nix-core)

;;; Group 1: nix--check

(ert-deftest nix-core-test-check-zero-exit-returns-stdout ()
  (should (equal "hello"
                 (nix--check '(:exit 0 :stdout "hello" :stderr "")))))

(ert-deftest nix-core-test-check-nonzero-exit-signals-error ()
  (let ((err (should-error
              (nix--check '(:exit 3 :stdout "" :stderr "boom") "myctx")
              :type 'error)))
    (should (string-match-p "myctx" (cadr err)))
    (should (string-match-p "boom" (cadr err)))))

(ert-deftest nix-core-test-check-default-context ()
  (let ((err (should-error
              (nix--check '(:exit 1 :stdout "" :stderr "oops")))))
    (should (string-match-p "nix" (cadr err)))))

;;; Group 2: nix--result-json

(ert-deftest nix-core-test-result-json-object ()
  (should (equal '((a . 1) (b . 2))
                 (nix--result-json
                  '(:exit 0 :stdout "{\"a\":1,\"b\":2}" :stderr "")))))

(ert-deftest nix-core-test-result-json-array ()
  (should (equal '(1 2 3)
                 (nix--result-json
                  '(:exit 0 :stdout "[1,2,3]" :stderr "")))))

(ert-deftest nix-core-test-result-json-nested ()
  (let ((parsed (nix--result-json
                 '(:exit 0 :stdout "{\"outer\":{\"inner\":[\"x\",\"y\"]}}" :stderr ""))))
    (should (equal '("x" "y")
                   (alist-get 'inner (alist-get 'outer parsed))))))

;;; Group 3: nix--result-lines

(ert-deftest nix-core-test-result-lines-splits ()
  (should (equal '("a" "b" "c")
                 (nix--result-lines
                  '(:exit 0 :stdout "a\nb\nc" :stderr "")))))

(ert-deftest nix-core-test-result-lines-drops-empty-and-trailing ()
  (should (equal '("a" "b")
                 (nix--result-lines
                  '(:exit 0 :stdout "a\n\nb\n" :stderr "")))))

;;; Group 4: nix--call (hermetic, /bin/sh)

(ert-deftest nix-core-test-call-captures-nonzero-plist ()
  (let ((result (nix--call "sh" '("-c" "echo out; echo err >&2; exit 3"))))
    (should (equal 3 (plist-get result :exit)))
    (should (equal "out\n" (plist-get result :stdout)))
    (should (equal "err\n" (plist-get result :stderr)))))

(ert-deftest nix-core-test-call-zero-exit ()
  (let ((result (nix--call "sh" '("-c" "echo done"))))
    (should (equal 0 (plist-get result :exit)))
    (should (equal "done\n" (plist-get result :stdout)))
    (should (equal "" (plist-get result :stderr)))))

;;; Group 5: nix--start (async, /bin/sh)

(defun nix-core-test--wait (pred &optional timeout)
  "Pump the event loop until PRED returns non-nil or TIMEOUT elapses."
  (let ((deadline (+ (float-time) (or timeout 5))))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.05))))

(ert-deftest nix-core-test-start-invokes-callback-with-plist ()
  (let (captured)
    (nix--start "sh" '("-c" "echo hi; echo oops >&2; exit 2")
                (lambda (result) (setq captured result)))
    (nix-core-test--wait (lambda () captured))
    (should captured)
    (should (equal 2 (plist-get captured :exit)))
    (should (equal "hi\n" (plist-get captured :stdout)))
    (should (equal "oops\n" (plist-get captured :stderr)))))

;;; Group 6: instantiate registry helpers

(ert-deftest nix-core-test-instantiate-key-plain ()
  (should (equal (expand-file-name "/tmp/x.nix")
                 (nix--instantiate-key "/tmp/x.nix" nil))))

(ert-deftest nix-core-test-instantiate-key-attribute ()
  (should (equal (concat (expand-file-name "/tmp/x.nix") "!pkg")
                 (nix--instantiate-key "/tmp/x.nix" "pkg"))))

(ert-deftest nix-core-test-instantiate-args ()
  (should (equal (list (expand-file-name "/tmp/x.nix") "-A" "pkg")
                 (nix--instantiate-args "/tmp/x.nix" "pkg")))
  (should (equal (list (expand-file-name "/tmp/x.nix"))
                 (nix--instantiate-args "/tmp/x.nix" nil))))

(ert-deftest nix-core-test-instantiate-register-first-is-nil ()
  (let ((nix--instantiate-registry (make-hash-table :test #'equal)))
    (should-not (nix--instantiate-register "k" #'ignore))
    (should (nix--instantiate-register "k" #'ignore))))

(ert-deftest nix-core-test-instantiate-dispatch-runs-and-clears ()
  (let ((nix--instantiate-registry (make-hash-table :test #'equal))
        results)
    (nix--instantiate-register "k" (lambda (v) (push (cons 1 v) results)))
    (nix--instantiate-register "k" (lambda (v) (push (cons 2 v) results)))
    (nix--instantiate-dispatch "k" "drv")
    (should (equal '((1 . "drv") (2 . "drv")) (sort results #'car-less-than-car)))
    (should-not (gethash "k" nix--instantiate-registry))))

(ert-deftest nix-core-test-instantiate-async-failure-clears-registry ()
  "A failed instantiation clears the key and skips the callback."
  (let ((nix--instantiate-registry (make-hash-table :test #'equal))
        (nix-instantiate-executable "false")
        (inhibit-message t)
        (called nil))
    (nix-instantiate-async (lambda (_drv) (setq called t)) "/tmp/x.nix")
    (let ((key (nix--instantiate-key "/tmp/x.nix" nil)))
      (nix-core-test--wait
       (lambda () (not (gethash key nix--instantiate-registry))))
      (should-not (gethash key nix--instantiate-registry))
      (should-not called))))

;;; Group 7: completion parsing

(ert-deftest nix-core-test-parse-completions-drops-mode-line ()
  (should (equal '("build" "run" "eval")
                 (nix--parse-completions
                  "normal\nbuild\trun a build\nrun\t\neval\teval expr\n"))))

(ert-deftest nix-core-test-parse-completions-empty ()
  (should (equal '() (nix--parse-completions "normal\n"))))

(provide 'nix-test-core)
;;; nix-test-core.el ends here
