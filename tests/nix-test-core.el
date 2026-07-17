;;; nix-test-core.el --- Tests for nix-core  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Thanos Apollo

;;; Commentary:

;; Pure and hermetic tests for the nix-core process layer.  No test here
;; requires the real nix binary or network access; process tests use
;; /bin/sh fixtures instead.

;;; Code:

(require 'cl-lib)
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

(ert-deftest nix-core-test-start-waits-for-stderr-and-calls-back-once ()
  (let ((make-pipe-process-original (symbol-function 'make-pipe-process))
        (process-live-p-original (symbol-function 'process-live-p))
        stderr-process
        (hold-stderr t)
        (count 0)
        result)
    (cl-letf (((symbol-function 'make-pipe-process)
               (lambda (&rest args)
                 (setq stderr-process
                       (apply make-pipe-process-original args))))
              ((symbol-function 'process-live-p)
               (lambda (process)
                 (or (and hold-stderr (eq process stderr-process))
                     (funcall process-live-p-original process)))))
      (let ((process
             (nix--start "sh" '("-c" "printf out; printf err >&2; exit 7")
                         (lambda (value)
                           (setq count (1+ count)
                                 result value)))))
        (nix-core-test--wait
         (lambda () (not (funcall process-live-p-original process))))
        (should (processp process))
        (should (= 0 count))
        (setq hold-stderr nil)
        (funcall (process-sentinel process) process "finished\n")
        (nix-core-test--wait (lambda () (> count 0)))
        (nix-core-test--wait (lambda () nil) 0.1)
        (should (= 1 count))
        (should (= 7 (plist-get result :exit)))
        (should (equal "out" (plist-get result :stdout)))
        (should (equal "err" (plist-get result :stderr)))))))

(ert-deftest nix-core-test-start-cleans-up-when-process-creation-fails ()
  (let ((buffers (buffer-list))
        (processes (process-list))
        quit-signaled)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _) (signal 'quit nil))))
      (condition-case nil
          (nix--start "sh" '("-c" "exit 0") #'ignore)
        (quit (setq quit-signaled t))))
    (should quit-signaled)
    (should (equal buffers (buffer-list)))
    (should (equal processes (process-list)))))

(ert-deftest nix-core-test-start-cleans-up-when-buffer-allocation-fails ()
  (dolist (condition '(error quit))
    (let ((buffers (buffer-list))
          (processes (process-list))
          (generate (symbol-function 'generate-new-buffer))
          (calls 0)
          caught)
      (cl-letf (((symbol-function 'generate-new-buffer)
                 (lambda (&rest args)
                   (setq calls (1+ calls))
                   (if (= calls 2)
                       (signal condition nil)
                     (apply generate args)))))
        (condition-case err
            (nix--start "sh" '("-c" "exit 0") #'ignore)
          (error (setq caught err))
          (quit (setq caught err))))
      (should (eq condition (car caught)))
      (should (equal buffers (buffer-list)))
      (should (equal processes (process-list))))))

(ert-deftest nix-core-test-instantiate-key-plain ()
  (should (equal (cons (expand-file-name "/tmp/x.nix") nil)
                 (nix--instantiate-key "/tmp/x.nix" nil))))

(ert-deftest nix-core-test-instantiate-key-attribute ()
  (should (equal (cons (expand-file-name "/tmp/x.nix") "pkg")
                 (nix--instantiate-key "/tmp/x.nix" "pkg"))))

(ert-deftest nix-core-test-instantiate-key-is-unambiguous ()
  (should-not (equal (nix--instantiate-key "/tmp/x!pkg" nil)
                     (nix--instantiate-key "/tmp/x" "pkg"))))

(ert-deftest nix-core-test-instantiate-args ()
  (should (equal (list (expand-file-name "/tmp/x.nix") "-A" "pkg")
                 (nix--instantiate-args "/tmp/x.nix" "pkg")))
  (should (equal (list (expand-file-name "/tmp/x.nix"))
                 (nix--instantiate-args "/tmp/x.nix" nil))))

(ert-deftest nix-core-test-colliding-inputs-start-distinct-processes ()
  "Formerly colliding inputs keep separate processes and callback results."
  (let ((nix--instantiate-registry (make-hash-table :test #'equal))
        starts
        results)
    (cl-letf (((symbol-function 'nix--start)
               (lambda (_program args callback)
                 (push (cons args callback) starts)
                 (make-symbol "process"))))
      (nix-instantiate-async
       (lambda (value) (push (cons 'file value) results)) "/tmp/x!pkg")
      (nix-instantiate-async
       (lambda (value) (push (cons 'attribute value) results))
       "/tmp/x" "pkg"))
    (should (= 2 (length starts)))
    (dolist (start starts)
      (funcall (cdr start)
               (list :exit 0
                     :stdout (if (member "-A" (car start))
                                 "drv-attribute\n"
                               "drv-file\n")
                     :stderr "")))
    (should (member '(file . "drv-file") results))
    (should (member '(attribute . "drv-attribute") results))
    (should (= 0 (hash-table-count nix--instantiate-registry)))))

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

(ert-deftest nix-core-test-instantiate-dispatch-isolates-entry-errors ()
  (let ((nix--instantiate-registry (make-hash-table :test #'equal))
        seen
        quit-signaled)
    (nix--instantiate-register
     "key"
     (lambda (_value)
       (should-not (gethash "key" nix--instantiate-registry))
       (push 'older-callback seen))
     (lambda ()
       (should-not (gethash "key" nix--instantiate-registry))
       (push 'older-finalizer seen)))
    (nix--instantiate-register
     "key"
     (lambda (_value)
       (should-not (gethash "key" nix--instantiate-registry))
       (push 'newer-callback seen)
       (signal 'quit nil))
     (lambda ()
       (should-not (gethash "key" nix--instantiate-registry))
       (push 'newer-finalizer seen)
       (signal 'quit nil)))
    (condition-case nil
        (nix--instantiate-dispatch "key" "drv")
      (quit (setq quit-signaled t)))
    (should quit-signaled)
    (should (equal '(newer-callback newer-finalizer
                    older-callback older-finalizer)
                   (reverse seen)))
    (should-not (gethash "key" nix--instantiate-registry))))

(ert-deftest nix-core-test-instantiate-fail-isolates-finalizer-errors ()
  (let ((nix--instantiate-registry (make-hash-table :test #'equal))
        seen
        quit-signaled)
    (nix--instantiate-register
     "key" #'ignore (lambda () (push 'older-finalizer seen)))
    (nix--instantiate-register
     "key" #'ignore
     (lambda () (push 'newer-finalizer seen) (signal 'quit nil)))
    (condition-case nil
        (nix--instantiate-fail "key")
      (quit (setq quit-signaled t)))
    (should quit-signaled)
    (should (equal '(newer-finalizer older-finalizer) (reverse seen)))
    (should-not (gethash "key" nix--instantiate-registry))))

(ert-deftest nix-core-test-instantiate-async-failure-clears-registry ()
  "A failed instantiation clears the key, skips CALLBACK, and finalizes."
  (let ((nix--instantiate-registry (make-hash-table :test #'equal))
        (nix-instantiate-executable "false")
        (inhibit-message t)
        (called nil)
        (finalized nil))
    (nix-instantiate-async (lambda (_drv) (setq called t)) "/tmp/x.nix" nil
                           (lambda () (setq finalized t)))
    (let ((key (nix--instantiate-key "/tmp/x.nix" nil)))
      (nix-core-test--wait
       (lambda () (not (gethash key nix--instantiate-registry))))
      (should-not (gethash key nix--instantiate-registry))
      (should-not called)
      (should finalized))))

(ert-deftest nix-core-test-instantiate-creation-error-finalizes ()
  (let ((nix--instantiate-registry (make-hash-table :test #'equal))
        finalized)
    (cl-letf (((symbol-function 'nix--start)
               (lambda (&rest _) (error "creation failed"))))
      (should-error
       (nix-instantiate-async #'ignore "/tmp/x.nix" nil
                              (lambda () (setq finalized t)))))
    (should (= 0 (hash-table-count nix--instantiate-registry)))
    (should finalized)))

;;; Group 7: output unquoting

(ert-deftest nix-core-test-unquote-strips-quotes-and-newline ()
  (should (equal "x86_64-linux" (nix--unquote "\"x86_64-linux\"\n"))))

(ert-deftest nix-core-test-unquote-plain-string-unchanged ()
  (should (equal "plain" (nix--unquote "plain\n"))))

;;; Group 8: completion parsing

;; `nix--parse-completions' returns `(MODE . CANDIDATES)': MODE is the
;; mode-marker symbol Nix emits on the first line (nil for empty output),
;; CANDIDATES the first tab-separated field of each remaining line.

(ert-deftest nix-core-test-parse-completions-normal-mode ()
  (should (equal '(normal . ("build" "run" "eval"))
                 (nix--parse-completions
                  "normal\nbuild\trun a build\nrun\t\neval\teval expr\n"))))

(ert-deftest nix-core-test-parse-completions-filenames-mode ()
  (should (equal '(filenames . ("./default.nix"))
                 (nix--parse-completions "filenames\n./default.nix\t\n"))))

(ert-deftest nix-core-test-parse-completions-attrs-mode ()
  (should (equal '(attrs . ("packages.x86_64-linux.default"))
                 (nix--parse-completions
                  "attrs\npackages.x86_64-linux.default\tthe default\n"))))

(ert-deftest nix-core-test-parse-completions-mode-only-has-no-candidates ()
  "A mode line with no rows yields the mode and an empty candidate list."
  (should (equal '(normal) (nix--parse-completions "normal\n"))))

(ert-deftest nix-core-test-parse-completions-empty-output ()
  "Empty output yields no mode and no candidates."
  (should (equal '(nil) (nix--parse-completions ""))))

(provide 'nix-test-core)
;;; nix-test-core.el ends here
