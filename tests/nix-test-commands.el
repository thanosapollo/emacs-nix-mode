;;; nix-test-commands.el --- Tests for nix-commands  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Thanos Apollo

;;; Commentary:

;; Pure and hermetic tests for nix-commands.  No test here requires the
;; real nix binary or network access: argument builders, the "nix edit"
;; output parser and the search renderer are exercised directly, and the
;; read helpers are driven through let-bound state.

;;; Code:

(require 'ert)
(require 'nix-commands)

;; `nix-file' and `nix-flake' are dir-locals variables owned by the
;; nix-shell module.  Declare them dynamic here so the let-bindings below
;; are visible to the `bound-and-true-p' lookups in the read helpers.
(defvar nix-file)
(defvar nix-flake)

;;; Group 1: nix-build--args

(ert-deftest nix-commands-test-build-args-with-attr ()
  (let ((nix-build-arguments nil))
    (should (equal (list (expand-file-name "default.nix") "-A" "hello")
                   (nix-build--args "default.nix" "hello")))))

(ert-deftest nix-commands-test-build-args-without-attr ()
  (let ((nix-build-arguments nil))
    (should (equal (list (expand-file-name "default.nix"))
                   (nix-build--args "default.nix" nil)))))

(ert-deftest nix-commands-test-build-args-prepends-extra ()
  (let ((nix-build-arguments '("--no-out-link")))
    (should (equal (list "--no-out-link" (expand-file-name "x.nix") "-A" "a")
                   (nix-build--args "x.nix" "a")))))

(ert-deftest nix-commands-test-build-buffer-name-uses-attr ()
  (should (equal "*nix-build*<hello>"
                 (nix-build--buffer-name "default.nix" "hello"))))

(ert-deftest nix-commands-test-build-buffer-name-falls-back-to-file ()
  (should (equal "*nix-build*<default.nix>"
                 (nix-build--buffer-name "/tmp/default.nix" nil))))

;;; Group 2: nix-log--args

(ert-deftest nix-commands-test-log-args ()
  (should (equal '("log" "/nix/store/abc.drv")
                 (nix-log--args "/nix/store/abc.drv"))))

;;; Group 3: nix-edit--args and parser

(ert-deftest nix-commands-test-edit-args ()
  (should (equal (list "edit" "-f" (expand-file-name "pkgs.nix") "hello")
                 (nix-edit--args "pkgs.nix" "hello"))))

(ert-deftest nix-commands-test-edit-args-requires-attribute ()
  (should-error (nix-edit--args "pkgs.nix" nil) :type 'user-error)
  (should-error (nix-edit--args "pkgs.nix" "") :type 'user-error))

(ert-deftest nix-commands-test-edit-parse-plain-file ()
  (should (equal '("/nix/store/src/hello.nix" . nil)
                 (nix-edit--parse "/nix/store/src/hello.nix\n"))))

(ert-deftest nix-commands-test-edit-parse-file-and-line ()
  (should (equal '("/nix/store/src/hello.nix" . 42)
                 (nix-edit--parse "/nix/store/src/hello.nix:42"))))

(ert-deftest nix-commands-test-edit-parse-windows-colon-edge ()
  "A drive-letter colon must not be mistaken for a line separator."
  (should (equal '("C:/src/hello.nix" . 7)
                 (nix-edit--parse "C:/src/hello.nix:7"))))

(ert-deftest nix-commands-test-edit-parse-windows-no-line ()
  (should (equal '("C:/src/hello.nix" . nil)
                 (nix-edit--parse "C:/src/hello.nix"))))

(ert-deftest nix-commands-test-edit-parse-empty ()
  (should-not (nix-edit--parse ""))
  (should-not (nix-edit--parse "   \n")))

;;; Group 4: nix-search--args

(ert-deftest nix-commands-test-search-args-with-query ()
  (should (equal '("search" "nixpkgs" "hello" "--json")
                 (nix-search--args "nixpkgs" "hello"))))

(ert-deftest nix-commands-test-search-args-empty-query ()
  (should (equal '("search" "nixpkgs" "--json")
                 (nix-search--args "nixpkgs" ""))))

(ert-deftest nix-commands-test-search-args-nil-query ()
  (should (equal '("search" "nixpkgs" "--json")
                 (nix-search--args "nixpkgs" nil))))

;;; Group 5: nix-search rendering

(defconst nix-commands-test--search-fixture
  '((legacyPackages\.x86_64-linux\.hello
     . ((pname . "hello")
        (version . "2.12.1")
        (description . "A program that produces a familiar, friendly greeting")))
    (legacyPackages\.x86_64-linux\.cowsay
     . ((pname . "cowsay")
        (version . "3.7.0")
        (description . "A program which generates ASCII pictures of a cow"))))
  "Fixture mirroring a decoded \"nix search --json\" alist.")

(ert-deftest nix-commands-test-search-render-entry-content ()
  (let ((string (nix-search--render-entry
                 'legacyPackages\.x86_64-linux\.hello
                 (cdr (car nix-commands-test--search-fixture)))))
    (should (string-match-p "hello" string))
    (should (string-match-p "2\\.12\\.1" string))
    (should (string-match-p "friendly greeting" string))))

(ert-deftest nix-commands-test-search-render-entry-faces ()
  (let ((string (nix-search--render-entry
                 'legacyPackages\.x86_64-linux\.hello
                 (cdr (car nix-commands-test--search-fixture)))))
    (should (eq 'nix-search-pname
                (get-text-property (string-search "hello" string) 'face string)))
    (should (eq 'nix-search-version
                (get-text-property (string-search "2.12.1" string) 'face string)))
    (should (eq 'nix-search-description
                (get-text-property (string-search "friendly" string) 'face string)))))

(ert-deftest nix-commands-test-search-render-entry-falls-back-to-name ()
  "With no pname, the attribute path symbol names the entry."
  (let ((string (nix-search--render-entry 'foo\.bar '((version . "1.0")))))
    (should (string-match-p "foo\\.bar" string))))

(ert-deftest nix-commands-test-search-render-buffer ()
  (with-temp-buffer
    (nix-search--render nix-commands-test--search-fixture)
    (let ((text (buffer-string)))
      (should (string-match-p "hello" text))
      (should (string-match-p "cowsay" text)))))

;;; Group 6: read helpers

(ert-deftest nix-commands-test-read-file-prefers-nix-file ()
  (let ((nix-file "dir-locals.nix"))
    (should (equal "dir-locals.nix" (nix-commands--read-file)))))

(ert-deftest nix-commands-test-read-file-uses-existing-file ()
  (let ((nix-file nil)
        (default-directory (make-temp-file "nix-commands-test" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "default.nix" default-directory)
            (insert "{}"))
          (should (equal "default.nix" (nix-commands--read-file))))
      (delete-directory default-directory t))))

(ert-deftest nix-commands-test-read-flake-prefers-nix-flake ()
  (let ((nix-flake "github:foo/bar")
        (default-directory temporary-file-directory))
    (should (equal "github:foo/bar" (nix-commands--read-flake)))))

(provide 'nix-test-commands)
;;; nix-test-commands.el ends here
