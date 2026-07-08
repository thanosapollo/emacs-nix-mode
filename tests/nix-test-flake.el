;;; nix-test-flake.el --- Tests for nix-flake  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Thanos Apollo

;;; Commentary:

;; Pure tests for `nix-flake'.  Every test drives a pure seam: the option
;; toggles mapping, the command builders, the attribute extraction over a
;; frozen "nix flake show --json" fixture, the input-name extraction over
;; a "nix flake metadata --json" fixture, and the registry-list parser.
;; No test runs the real nix binary; `nix-system' is stubbed where a
;; builder or extractor needs the current system tuple.

;;; Code:

(require 'ert)
(require 'nix-flake)

;;; Fixtures

;; Trimmed from a real "nix flake metadata --json" run in this repo
;; (Nix 2.34.7); only the locks tree the parser reads is kept.
(defconst nix-flake-test--metadata
  "{\"locks\":{\"nodes\":{\"nixpkgs\":{\"locked\":{\"type\":\"github\"}},\
\"root\":{\"inputs\":{\"nixpkgs\":\"nixpkgs\"}}},\"root\":\"root\"}}"
  "A realistic single-input metadata fixture.")

(defconst nix-flake-test--metadata-multi
  "{\"locks\":{\"nodes\":{\"root\":{\"inputs\":\
{\"nixpkgs\":\"nixpkgs\",\"flake-utils\":\"flake-utils\"}}},\"root\":\"root\"}}"
  "A metadata fixture with two inputs.")

;; Shaped like real "nix flake show --json" output: outputs keyed by
;; type, then by system tuple, then by attribute name.
(defconst nix-flake-test--show
  "{\"packages\":{\"x86_64-linux\":{\"default\":{\"type\":\"derivation\"},\
\"hello\":{\"type\":\"derivation\"}},\"aarch64-linux\":{\"other\":{}}},\
\"apps\":{\"x86_64-linux\":{\"run\":{\"type\":\"app\"}}},\
\"devShells\":{\"x86_64-linux\":{\"default\":{}}}}"
  "A flake-show fixture with packages, apps and devShells.")

(defmacro nix-flake-test--with-system (system &rest body)
  "Run BODY with `nix-system' stubbed to return SYSTEM."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'nix-system) (lambda () ,system)))
	    ,@body))

(defun nix-flake-test--json (string)
  "Parse STRING as a nix-core alist JSON result."
  (nix--result-json (list :exit 0 :stdout string :stderr "")))

;;; Group 1: reference resolution

(ert-deftest nix-flake-test-current-ref-explicit ()
  (let ((nix-flake--ref "github:owner/repo"))
    (should (equal "github:owner/repo" (nix-flake--current-ref)))))

(ert-deftest nix-flake-test-dir-ref-is-path-url ()
  (should (equal "path:/tmp/proj" (nix-flake--dir-ref "/tmp/proj/"))))

;;; Group 2: option toggles

(ert-deftest nix-flake-test-options-all-off ()
  (let ((nix-flake--impure nil)
        (nix-flake--no-update-lock-file nil)
        (nix-flake--commit-lock-file nil)
        (nix-flake--print-build-logs nil))
    (should-not (nix-flake--options))))

(ert-deftest nix-flake-test-options-impure ()
  (let ((nix-flake--impure t)
        (nix-flake--no-update-lock-file nil)
        (nix-flake--commit-lock-file nil)
        (nix-flake--print-build-logs nil))
    (should (equal '("--impure") (nix-flake--options)))))

(ert-deftest nix-flake-test-options-no-update ()
  (let ((nix-flake--impure nil)
        (nix-flake--no-update-lock-file t)
        (nix-flake--commit-lock-file nil)
        (nix-flake--print-build-logs nil))
    (should (equal '("--no-update-lock-file") (nix-flake--options)))))

(ert-deftest nix-flake-test-options-commit ()
  (let ((nix-flake--impure nil)
        (nix-flake--no-update-lock-file nil)
        (nix-flake--commit-lock-file t)
        (nix-flake--print-build-logs nil))
    (should (equal '("--commit-lock-file") (nix-flake--options)))))

(ert-deftest nix-flake-test-options-print-build-logs ()
  (let ((nix-flake--impure nil)
        (nix-flake--no-update-lock-file nil)
        (nix-flake--commit-lock-file nil)
        (nix-flake--print-build-logs t))
    (should (equal '("--print-build-logs") (nix-flake--options)))))

(ert-deftest nix-flake-test-options-preserves-flag-order ()
  (let ((nix-flake--impure t)
        (nix-flake--no-update-lock-file nil)
        (nix-flake--commit-lock-file t)
        (nix-flake--print-build-logs t))
    (should (equal '("--impure" "--commit-lock-file" "--print-build-logs")
                   (nix-flake--options)))))

;;; Group 3: command builders

(defmacro nix-flake-test--with-ref (ref &rest body)
  "Run BODY with the flake reference fixed to REF and options off."
  (declare (indent 1))
  `(let ((nix-flake--ref ,ref)
         (nix-flake--impure nil)
         (nix-flake--no-update-lock-file nil)
         (nix-flake--commit-lock-file nil)
         (nix-flake--print-build-logs nil)
         (nix-executable "nix"))
     ,@body))

(ert-deftest nix-flake-test-command-check ()
  (nix-flake-test--with-ref "github:o/r"
			    (should (equal '("nix" "flake" "check" "github:o/r")
					   (nix-flake--command "check")))))

(ert-deftest nix-flake-test-command-appends-options ()
  (nix-flake-test--with-ref "github:o/r"
			    (let ((nix-flake--impure t))
			      (should (equal '("nix" "flake" "check" "github:o/r" "--impure")
					     (nix-flake--command "check"))))))

(ert-deftest nix-flake-test-update-command-no-inputs ()
  (nix-flake-test--with-ref "github:o/r"
			    (should (equal '("nix" "flake" "update" "github:o/r")
					   (nix-flake--update-command)))))

(ert-deftest nix-flake-test-update-command-with-inputs ()
  (nix-flake-test--with-ref "github:o/r"
			    (should (equal '("nix" "flake" "update" "github:o/r" "nixpkgs" "flake-utils")
					   (nix-flake--update-command '("nixpkgs" "flake-utils"))))))

(ert-deftest nix-flake-test-installable-build-attribute ()
  (nix-flake-test--with-ref "github:o/r"
			    (should (equal '("nix" "build" "github:o/r#hello")
					   (nix-flake--installable "build" "hello")))))

(ert-deftest nix-flake-test-installable-run-default ()
  (nix-flake-test--with-ref "github:o/r"
			    (should (equal '("nix" "run" "github:o/r")
					   (nix-flake--installable "run")))))

(ert-deftest nix-flake-test-installable-appends-options ()
  (nix-flake-test--with-ref "github:o/r"
			    (let ((nix-flake--print-build-logs t))
			      (should (equal '("nix" "build" "github:o/r#hello" "--print-build-logs")
					     (nix-flake--installable "build" "hello"))))))

(ert-deftest nix-flake-test-init-command ()
  (let ((nix-executable "nix"))
    (should (equal '("nix" "flake" "init" "-t" "templates#rust")
                   (nix-flake--init-command "templates#rust")))))

;;; Group 4: attribute extraction from flake show

(ert-deftest nix-flake-test-build-attrs-current-system ()
  (nix-flake-test--with-system "x86_64-linux"
			       (let ((outputs (nix-flake-test--json nix-flake-test--show)))
				 (should (equal '("default" "hello")
						(sort (nix-flake--build-attrs outputs) #'string<))))))

(ert-deftest nix-flake-test-run-attrs-merges-apps-and-packages ()
  (nix-flake-test--with-system "x86_64-linux"
			       (let ((outputs (nix-flake-test--json nix-flake-test--show)))
				 (should (equal '("default" "hello" "run")
						(sort (nix-flake--run-attrs outputs) #'string<))))))

(ert-deftest nix-flake-test-build-attrs-other-system-empty ()
  (nix-flake-test--with-system "riscv64-linux"
			       (let ((outputs (nix-flake-test--json nix-flake-test--show)))
				 (should-not (nix-flake--build-attrs outputs)))))

(ert-deftest nix-flake-test-attrs-dedupes-across-types ()
  (nix-flake-test--with-system "x86_64-linux"
			       (let* ((outputs (nix-flake-test--json nix-flake-test--show))
				      (attrs (nix-flake--run-attrs outputs)))
				 (should (equal (length attrs) (length (delete-dups (copy-sequence attrs))))))))

;;; Group 5: metadata input extraction

(ert-deftest nix-flake-test-metadata-inputs-single ()
  (should (equal '("nixpkgs")
                 (nix-flake--metadata-inputs
                  (nix-flake-test--json nix-flake-test--metadata)))))

(ert-deftest nix-flake-test-metadata-inputs-multiple ()
  (should (equal '("flake-utils" "nixpkgs")
                 (sort (nix-flake--metadata-inputs
                        (nix-flake-test--json nix-flake-test--metadata-multi))
                       #'string<))))

;;; Group 6: registry parsing

(defconst nix-flake-test--registry-output
  "system flake:nixpkgs path:/nix/store/abc-source
global flake:agda github:agda/agda
user flake:mine github:me/mine"
  "Realistic three-line \"nix registry list\" output.")

(ert-deftest nix-flake-test-parse-registry-triples ()
  (should (equal '(("system" "flake:nixpkgs" "path:/nix/store/abc-source")
                   ("global" "flake:agda" "github:agda/agda")
                   ("user" "flake:mine" "github:me/mine"))
                 (nix-flake--parse-registry
                  (split-string nix-flake-test--registry-output "\n")))))

(ert-deftest nix-flake-test-parse-registry-drops-malformed ()
  (should (equal '(("user" "flake:mine" "github:me/mine"))
                 (nix-flake--parse-registry
                  '("garbage" "user flake:mine github:me/mine" "")))))

(ert-deftest nix-flake-test-registry-refs-excludes-system ()
  (let ((entries (nix-flake--parse-registry
                  (split-string nix-flake-test--registry-output "\n"))))
    (should (equal '("flake:agda" "github:agda/agda"
                     "flake:mine" "github:me/mine")
                   (nix-flake--registry-refs entries)))))

(ert-deftest nix-flake-test-registry-refs-dedupes ()
  (should (equal '("flake:x" "github:a/x")
                 (nix-flake--registry-refs
                  '(("user" "flake:x" "github:a/x")
                    ("global" "flake:x" "github:a/x"))))))

(provide 'nix-test-flake)
;;; nix-test-flake.el ends here
