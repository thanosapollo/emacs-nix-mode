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

;;; Group 4: interception predicate

(ert-deftest nix-shell-test-intercept-develop ()
  (should (nix-shell--eshell-intercept-p '("develop")))
  (should (nix-shell--eshell-intercept-p '("shell" "nixpkgs#hello"))))

(ert-deftest nix-shell-test-intercept-skips-explicit-command ()
  (should-not (nix-shell--eshell-intercept-p '("develop" "--command" "bash")))
  (should-not (nix-shell--eshell-intercept-p '("build")))
  (should-not (nix-shell--eshell-intercept-p '("flake" "show"))))

(ert-deftest nix-shell-test-capture-args ()
  (should (equal (list nix-executable "develop" "--command" "env" "-0")
                 (nix-shell--capture-args '("develop")))))

(ert-deftest nix-shell-test-parse-environment-preserves-shell-characters ()
  (should (equal '(("A" . "line 1\nline '2' \\")
                   ("B" . "x=y"))
                 (nix-shell--parse-environment
                  (concat "A=line 1\nline '2' \\" "\0"
                          "B=x=y" "\0")))))

;;; Group 5: phase argument builder

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

(ert-deftest nix-shell-test-packages-temp-file-cleaned-after-async-finish ()
  (let ((file (make-temp-file "nix-shell-test" nil ".nix"))
        cleanup)
    (cl-letf (((symbol-function 'nix-shell--packages-file)
               (lambda (&rest _) file))
              ((symbol-function 'nix-shell--apply-file)
               (lambda (_file &optional _attr finally)
                 (setq cleanup finally))))
      (nix-shell-with-packages '(hello))
      (should (file-exists-p file))
      (funcall cleanup)
      (should-not (file-exists-p file)))))

(ert-deftest nix-shell-test-packages-file-cleans-up-write-failure ()
  (let* ((directory (make-temp-file "nix-shell-test" t))
         (temporary-file-directory (file-name-as-directory directory)))
    (unwind-protect
        (cl-letf (((symbol-function 'write-region)
                   (lambda (&rest _) (error "write failed"))))
          (should-error (nix-shell--packages-file '(hello) "<nixpkgs>"))
          (should-not
           (directory-files directory nil directory-files-no-dot-files-regexp)))
      (delete-directory directory t))))

(ert-deftest nix-shell-test-packages-temp-file-cleaned-on-handoff-error ()
  (let ((file (make-temp-file "nix-shell-test" nil ".nix")))
    (cl-letf (((symbol-function 'nix-shell--packages-file)
               (lambda (&rest _) file))
              ((symbol-function 'nix-instantiate-async)
               (lambda (&rest _) (error "handoff failed"))))
      (should-error (nix-shell-with-packages '(hello)))
      (should-not (file-exists-p file)))))

(ert-deftest nix-shell-test-eshell-packages-temp-file-cleaned ()
  (let ((file (make-temp-file "nix-shell-test" nil ".nix")))
    (cl-letf (((symbol-function 'nix-shell--packages-file)
               (lambda (&rest _) file))
              ((symbol-function 'nix-shell--eshell-buffer)
               (lambda (_parse) :buffer)))
      (should (eq :buffer (nix-eshell-with-packages '(hello))))
      (should-not (file-exists-p file)))))

(ert-deftest nix-shell-test-eshell-packages-temp-file-cleaned-on-error ()
  (let ((file (make-temp-file "nix-shell-test" nil ".nix")))
    (cl-letf (((symbol-function 'nix-shell--packages-file)
               (lambda (&rest _) file))
              ((symbol-function 'nix-shell--eshell-buffer)
               (lambda (parse-derivation) (funcall parse-derivation)))
              ((symbol-function 'nix-instantiate)
               (lambda (&rest _) (error "instantiate failed"))))
      (should-error (nix-eshell-with-packages '(hello)))
      (should-not (file-exists-p file)))))

(ert-deftest nix-shell-test-eshell-mode-restores-existing-command ()
  (let ((original (lambda (&rest _) :original)))
    (unwind-protect
        (progn
          (fset 'eshell/nix original)
          (nix-eshell-integration-mode 1)
          (nix-eshell-integration-mode 1)
          (should (eq (symbol-function 'eshell/nix)
                      #'nix-shell--eshell-nix))
          (nix-eshell-integration-mode -1)
          (should (eq (symbol-function 'eshell/nix) original)))
      (nix-eshell-integration-mode -1)
      (fmakunbound 'eshell/nix))))

(provide 'nix-test-shell)
;;; nix-test-shell.el ends here
