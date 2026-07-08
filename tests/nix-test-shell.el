;;; nix-test-shell.el --- Tests for nix-shell  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Thanos Apollo

;;; Commentary:

;; Pure and hermetic tests for `nix-shell'.  Every test drives a pure
;; seam: the environment/input extraction over a frozen "nix derivation
;; show" fixture, exec-path building against temporary bin/ directories,
;; process-environment assembly (PATH ordering and --pure clearing), the
;; "sh -c export" line parser over hand-written fixtures, and the phase
;; argument builder.  No test runs the real nix binary.

;;; Code:

(require 'ert)
(require 'nix-shell)

;;; Fixtures

;; Trimmed from a real "nix derivation show" run in this repo (Nix
;; 2.34.7) on `mkShell { nativeBuildInputs = [ hello ]; buildInputs =
;; [ zlib ]; }'; only the `env' keys the extractors read are kept, with
;; the store paths shortened but structurally faithful.
(defconst nix-shell-test--derivation
  "{\"/nix/store/aaa-nix-shell.drv\":{\"env\":{\
\"buildInputs\":\"/nix/store/bbb-zlib-dev\",\
\"nativeBuildInputs\":\"/nix/store/ccc-hello\",\
\"propagatedBuildInputs\":\"\",\
\"propagatedNativeBuildInputs\":\"\",\
\"name\":\"nix-shell\",\
\"system\":\"x86_64-linux\"},\
\"name\":\"nix-shell\",\"system\":\"x86_64-linux\"}}"
  "A realistic single-derivation fixture keyed by drv path.")

(defconst nix-shell-test--derivation-multi
  "{\"/nix/store/aaa.drv\":{\"env\":{\
\"buildInputs\":\"/nix/store/one /nix/store/two\",\
\"nativeBuildInputs\":\"/nix/store/three\",\
\"LD_LIBRARY_PATH\":\"/nix/store/one/lib\"}}}"
  "A fixture with multiple space-separated inputs and LD_LIBRARY_PATH.")

(defun nix-shell-test--parse (string)
  "Parse STRING as a nix-core alist JSON result."
  (nix--result-json (list :exit 0 :stdout string :stderr "")))

(defun nix-shell-test--drv (string)
  "Return the single derivation alist parsed from STRING."
  (nix-shell--derivation (nix-shell-test--parse string)))

;;; Group 1: environment and input extraction

(ert-deftest nix-shell-test-env-returns-alist ()
  (let ((env (nix-shell--env (nix-shell-test--drv nix-shell-test--derivation))))
    (should (equal "/nix/store/ccc-hello" (alist-get 'nativeBuildInputs env)))
    (should (equal "x86_64-linux" (alist-get 'system env)))))

(ert-deftest nix-shell-test-inputs-collects-configured-keys ()
  (should (equal '("/nix/store/bbb-zlib-dev" "/nix/store/ccc-hello")
                 (nix-shell--inputs
                  (nix-shell-test--drv nix-shell-test--derivation)))))

(ert-deftest nix-shell-test-inputs-splits-and-drops-empty ()
  (should (equal '("/nix/store/one" "/nix/store/two" "/nix/store/three")
                 (nix-shell--inputs
                  (nix-shell-test--drv nix-shell-test--derivation-multi)))))

(ert-deftest nix-shell-test-inputs-honours-custom-keys ()
  (let ((nix-shell-inputs '(nativeBuildInputs)))
    (should (equal '("/nix/store/ccc-hello")
                   (nix-shell--inputs
                    (nix-shell-test--drv nix-shell-test--derivation))))))

;;; Group 2: exec-path building against real directories

(defmacro nix-shell-test--with-store (paths &rest body)
  "Bind PATHS to temp store dirs with a bin/ subdir, run BODY.
PATHS is a list of symbols; each is bound to a fresh temp directory
whose \"bin\" subdirectory exists.  The directories are removed
afterwards."
  (declare (indent 1))
  `(let ,(mapcar (lambda (sym) `(,sym (make-temp-file "nix-shell-test" t))) paths)
     (unwind-protect
         (progn
           ,@(mapcar (lambda (sym)
                       `(make-directory (expand-file-name "bin" ,sym) t))
                     paths)
           ,@body)
       ,@(mapcar (lambda (sym) `(delete-directory ,sym t)) paths))))

(ert-deftest nix-shell-test-exec-path-keeps-existing-bins ()
  (nix-shell-test--with-store (a b)
    (should (equal (list (expand-file-name "bin" a)
                         (expand-file-name "bin" b))
                   (nix-shell--exec-path (list a b))))))

(ert-deftest nix-shell-test-exec-path-drops-missing ()
  (nix-shell-test--with-store (a)
    (should (equal (list (expand-file-name "bin" a))
                   (nix-shell--exec-path
                    (list a "/nix/store/does-not-exist"))))))

;;; Group 3: process-environment assembly

(ert-deftest nix-shell-test-process-environment-prepends-path ()
  (let* ((drv (nix-shell-test--drv nix-shell-test--derivation))
         (env (nix-shell--process-environment
               drv '("/store/bin") '("PATH=/usr/bin") nil))
         (process-environment env))
    (should (equal "/store/bin:/usr/bin" (getenv "PATH")))))

(ert-deftest nix-shell-test-process-environment-clear-drops-base ()
  (let* ((drv (nix-shell-test--drv nix-shell-test--derivation))
         (env (nix-shell--process-environment
               drv '("/store/bin") '("PATH=/usr/bin") t))
         (process-environment env))
    (should (equal "/store/bin" (getenv "PATH")))))

(ert-deftest nix-shell-test-process-environment-adds-ld-library-path ()
  (let* ((drv (nix-shell-test--drv nix-shell-test--derivation-multi))
         (env (nix-shell--process-environment
               drv '("/store/bin") '("PATH=/usr/bin") t))
         (process-environment env))
    (should (equal "/nix/store/one/lib" (getenv "LD_LIBRARY_PATH")))))

(ert-deftest nix-shell-test-process-environment-merges-ld-library-path ()
  (let* ((drv (nix-shell-test--drv nix-shell-test--derivation-multi))
         (env (nix-shell--process-environment
               drv '("/store/bin")
               '("PATH=/usr/bin" "LD_LIBRARY_PATH=/existing") nil))
         (process-environment env))
    (should (equal "/nix/store/one/lib:/existing"
                   (getenv "LD_LIBRARY_PATH")))))

(ert-deftest nix-shell-test-path-string-empty-base ()
  (should (equal "/a:/b" (nix-shell--path-string '("/a" "/b") "")))
  (should (equal "/a:/b" (nix-shell--path-string '("/a" "/b") nil)))
  (should (equal "/a:/base" (nix-shell--path-string '("/a") "/base"))))

;;; Group 4: export-line parser

(ert-deftest nix-shell-test-parse-exports-simple ()
  (should (equal '(("FOO" . "bar"))
                 (nix-shell--parse-exports "export FOO=\"bar\""))))

(ert-deftest nix-shell-test-parse-exports-quoted-spaces ()
  (should (equal '(("FOO" . "bar baz"))
                 (nix-shell--parse-exports "export FOO=\"bar baz\""))))

(ert-deftest nix-shell-test-parse-exports-escaped-quote ()
  (should (equal '(("Q" . "has \"quote\""))
                 (nix-shell--parse-exports "export Q=\"has \\\"quote\\\"\""))))

(ert-deftest nix-shell-test-parse-exports-empty-value ()
  (should (equal '(("EMPTY" . ""))
                 (nix-shell--parse-exports "export EMPTY=\"\""))))

(ert-deftest nix-shell-test-parse-exports-skips-blocklist ()
  (should (equal '(("KEEP" . "yes"))
                 (nix-shell--parse-exports
                  (concat "export PWD=\"/tmp\"\n"
                          "export SHLVL=\"2\"\n"
                          "export KEEP=\"yes\"\n")))))

(ert-deftest nix-shell-test-parse-exports-ignores-non-export ()
  (should (equal '(("A" . "1"))
                 (nix-shell--parse-exports
                  (concat "declare -x A\nexport A=\"1\"\nrandom line\n")))))

(ert-deftest nix-shell-test-parse-exports-unquoted-value ()
  "A value with no surrounding quotes is kept verbatim."
  (should (equal '(("A" . "raw"))
                 (nix-shell--parse-exports "export A=raw"))))

;;; Group 5: interception predicate

(ert-deftest nix-shell-test-intercept-develop ()
  (should (nix-shell--eshell-intercept-p '("develop")))
  (should (nix-shell--eshell-intercept-p '("shell" "nixpkgs#hello"))))

(ert-deftest nix-shell-test-intercept-skips-explicit-command ()
  (should-not (nix-shell--eshell-intercept-p '("develop" "--command" "bash")))
  (should-not (nix-shell--eshell-intercept-p '("build")))
  (should-not (nix-shell--eshell-intercept-p '("flake" "show"))))

(ert-deftest nix-shell-test-capture-args ()
  (should (equal (list nix-executable "develop" "--command" "sh" "-c" "export")
                 (nix-shell--capture-args '("develop")))))

;;; Group 6: phase argument builder

(ert-deftest nix-shell-test-phase-args-with-attr ()
  (should (equal (list (expand-file-name "shell.nix") "-A" "hello"
                       "--run" (nix-shell--phase-script "unpack"))
                 (nix-shell--phase-args "unpack" "shell.nix" "hello"))))

(ert-deftest nix-shell-test-phase-args-without-attr ()
  (should (equal (list (expand-file-name "shell.nix")
                       "--run" (nix-shell--phase-script "build"))
                 (nix-shell--phase-args "build" "shell.nix" nil))))

(ert-deftest nix-shell-test-phase-script-mentions-phase ()
  (let ((script (nix-shell--phase-script "configure")))
    (should (string-match-p "configurePhase" script))))

;;; Group 7: safe-local-variable markers

(ert-deftest nix-shell-test-dir-locals-are-safe-strings ()
  (should (eq #'stringp (get 'nix-file 'safe-local-variable)))
  (should (eq #'stringp (get 'nix-attr 'safe-local-variable))))

(provide 'nix-test-shell)
;;; nix-test-shell.el ends here
