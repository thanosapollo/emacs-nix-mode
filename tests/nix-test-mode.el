;;; nix-test-mode.el --- Tests for nix-mode  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Thanos Apollo

;;; Commentary:

;; Tests for the tree-sitter major mode: indentation, font-lock, imenu,
;; defun navigation and `auto-mode-alist' wiring.  Every test that drives
;; the parser is guarded by `(skip-unless (treesit-ready-p 'nix t))', so
;; the file loads cleanly without the grammar; the grammar directory is
;; taken from the NIX_MODE_TS_DIR environment variable when set.

;;; Code:

(require 'ert)
(require 'treesit)

(let ((dir (getenv "NIX_MODE_TS_DIR")))
  (when dir (add-to-list 'treesit-extra-load-path dir)))

(require 'nix-mode)

(defmacro nix-mode-test--with-buffer (content &rest body)
  "Run BODY in a `nix-mode' buffer holding CONTENT.
Point starts at `point-min'."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (nix-mode)
     (insert ,content)
     (goto-char (point-min))
     ,@body))

;;; Group 1: indentation

;; Each snippet is already correctly indented.  The indentation test
;; strips every line back to column zero and re-indents the whole buffer,
;; asserting the result matches the original.  The idempotence test
;; indents the already-correct snippet and asserts nothing changes.

(defconst nix-mode-test--indent-snippets
  '(("nested-attrset" . "{
  a = {
    b = 1;
  };
}")
    ("rec-attrset" . "rec {
  a = 1;
  b = a;
}")
    ("let-in-body" . "let
  x = 1;
in
x")
    ("if-then-else" . "if a then
  b
else
  c")
    ("lambda-formals" . "{ a, b ? 1, ... }@args:
body")
    ("list-of-attrsets" . "[
  { a = 1; }
  { b = 2; }
]")
    ("apply-chain" . "foo
  bar
  baz")
    ("inherit-wrapped" . "{
  inherit (pkgs)
    hello
    world
    ;
}")
    ("nested-let-in-attrset" . "{
  x = let
    y = 1;
  in
  y;
}")
    ("nested-parens-select" . "(foo.bar or
  baz)"))
  "Table of (NAME . WELL-INDENTED-SNIPPET) for the indentation tests.")

(defconst nix-mode-test--indented-string "{
  script = ''
        weird inner indent
    two spaces
  '';
}"
  "A snippet whose indented-string body must survive `indent-region'.
Flattening would destroy the inner whitespace, so this is only used
for the idempotence and preservation checks, not the flatten test.")

(defun nix-mode-test--flatten ()
  "Remove all leading whitespace from every line in the buffer."
  (goto-char (point-min))
  (while (not (eobp))
    (delete-horizontal-space)
    (forward-line 1)))

(ert-deftest nix-mode-test-indent-reindents-flattened ()
  "Flattening then re-indenting reproduces each snippet."
  (skip-unless (treesit-ready-p 'nix t))
  (dolist (entry nix-mode-test--indent-snippets)
    (ert-info ((car entry) :prefix "snippet: ")
      (nix-mode-test--with-buffer (cdr entry)
                                  (nix-mode-test--flatten)
                                  (indent-region (point-min) (point-max))
                                  (should (string-equal (cdr entry) (buffer-string)))))))

(ert-deftest nix-mode-test-indent-is-idempotent ()
  "Re-indenting an already-correct snippet changes nothing."
  (skip-unless (treesit-ready-p 'nix t))
  (dolist (entry nix-mode-test--indent-snippets)
    (ert-info ((car entry) :prefix "snippet: ")
      (nix-mode-test--with-buffer (cdr entry)
                                  (indent-region (point-min) (point-max))
                                  (should (string-equal (cdr entry) (buffer-string)))))))

(ert-deftest nix-mode-test-indent-preserves-indented-string ()
  "Weird indentation inside an indented string survives re-indentation."
  (skip-unless (treesit-ready-p 'nix t))
  (nix-mode-test--with-buffer nix-mode-test--indented-string
                              (indent-region (point-min) (point-max))
                              (should (string-equal nix-mode-test--indented-string (buffer-string)))))

;;; Group 2: font-lock

(defun nix-test--face-at (content needle)
  "Return the face at the first character of NEEDLE in CONTENT."
  (nix-mode-test--with-buffer content
                              (font-lock-ensure)
                              (goto-char (point-min))
                              (search-forward needle)
                              (goto-char (match-beginning 0))
                              (get-text-property (point) 'face)))

(ert-deftest nix-mode-test-font-lock-keyword ()
  (skip-unless (treesit-ready-p 'nix t))
  (should (eq 'font-lock-keyword-face
              (nix-test--face-at "let x = 1; in x" "let")))
  (should (eq 'font-lock-keyword-face
              (nix-test--face-at "let x = 1; in x" "in")))
  (should (eq 'font-lock-keyword-face
              (nix-test--face-at "if a then b else c" "if"))))

(ert-deftest nix-mode-test-font-lock-string ()
  (skip-unless (treesit-ready-p 'nix t))
  (should (eq 'font-lock-string-face
              (nix-test--face-at "x = \"hello\";" "hello"))))

(ert-deftest nix-mode-test-font-lock-string-interpolation-not-string ()
  "Code inside `${...}' keeps its own fontification, not the string face.
The literal fragments around the interpolation stay `font-lock-string-face'."
  (skip-unless (treesit-ready-p 'nix t))
  ;; Double-quoted: the interpolated variable is not string-faced, but the
  ;; literal runs before and after it are.
  (should-not (eq 'font-lock-string-face
                  (nix-test--face-at "x = \"pre ${pkgs} post\";" "pkgs")))
  (should (eq 'font-lock-string-face
              (nix-test--face-at "x = \"pre ${pkgs} post\";" "pre ")))
  (should (eq 'font-lock-string-face
              (nix-test--face-at "x = \"pre ${pkgs} post\";" " post")))
  ;; Indented strings behave the same way.
  (should-not (eq 'font-lock-string-face
                  (nix-test--face-at "x = ''pre ${pkgs} post'';" "pkgs")))
  (should (eq 'font-lock-string-face
              (nix-test--face-at "x = ''pre ${pkgs} post'';" "pre ")))
  ;; A builtin inside an interpolation gets the builtin face, not string.
  (should (eq 'font-lock-builtin-face
              (nix-test--face-at "x = \"a ${toString y} b\";" "toString"))))

(ert-deftest nix-mode-test-font-lock-comment ()
  (skip-unless (treesit-ready-p 'nix t))
  (should (eq 'font-lock-comment-face
              (nix-test--face-at "# a comment\n1" "# a comment"))))

(ert-deftest nix-mode-test-font-lock-builtin ()
  (skip-unless (treesit-ready-p 'nix t))
  (should (eq 'font-lock-builtin-face
              (nix-test--face-at "builtins.fetchTarball x" "builtins")))
  (should (eq 'font-lock-builtin-face
              (nix-test--face-at "x = true;" "true")))
  (should (eq 'font-lock-builtin-face
              (nix-test--face-at "x = null;" "null"))))

(ert-deftest nix-mode-test-font-lock-interpolation ()
  "The ${ delimiter inside a string gets `nix-interpolation-face'."
  (skip-unless (treesit-ready-p 'nix t))
  (should (eq 'nix-interpolation-face
              (nix-test--face-at "x = \"a${b}c\";" "${"))))

(ert-deftest nix-mode-test-font-lock-number ()
  (skip-unless (treesit-ready-p 'nix t))
  (should (eq 'font-lock-number-face
              (nix-test--face-at "x = 42;" "42")))
  (should (eq 'font-lock-number-face
              (nix-test--face-at "x = 3.5;" "3.5"))))

(ert-deftest nix-mode-test-font-lock-path ()
  (skip-unless (treesit-ready-p 'nix t))
  (should (eq 'font-lock-constant-face
              (nix-test--face-at "x = ./foo/bar;" "./foo/bar")))
  (should (eq 'font-lock-constant-face
              (nix-test--face-at "x = <nixpkgs>;" "<nixpkgs>"))))

(ert-deftest nix-mode-test-font-lock-escape ()
  (skip-unless (treesit-ready-p 'nix t))
  (should (eq 'font-lock-escape-face
              (nix-test--face-at "x = \"a\\nb\";" "\\n"))))

;;; Group 3: imenu

(ert-deftest nix-mode-test-imenu-dotted-names ()
  "The imenu index carries dotted binding names."
  (skip-unless (treesit-ready-p 'nix t))
  (nix-mode-test--with-buffer
   "{\n  packages.x86_64-linux.default = 1;\n  foo = 2;\n}"
   (let* ((index (funcall imenu-create-index-function))
          (names (mapcar #'car (cdr (car index)))))
     (should (member "packages.x86_64-linux.default" names))
     (should (member "foo" names)))))

;;; Group 4: defun navigation

(ert-deftest nix-mode-test-defun-name-at-point ()
  "`treesit-defun-name' returns the dotted attrpath of the binding."
  (skip-unless (treesit-ready-p 'nix t))
  (nix-mode-test--with-buffer
   "{\n  packages.default = 1;\n  foo = 2;\n}"
   (search-forward "default")
   (should (equal "packages.default"
                  (treesit-defun-name (treesit-defun-at-point))))))

(ert-deftest nix-mode-test-beginning-of-defun ()
  "`beginning-of-defun' lands at the start of a binding."
  (skip-unless (treesit-ready-p 'nix t))
  (nix-mode-test--with-buffer
   "{\n  alpha = 1;\n  beta = 2;\n}"
   (goto-char (point-max))
   (search-backward "2")
   (beginning-of-defun)
   (back-to-indentation)
   (should (looking-at-p "beta"))))

;;; Group 5: auto-mode

(ert-deftest nix-mode-test-auto-mode-nix ()
  "A .nix file maps to `nix-mode'."
  (should (eq 'nix-mode
              (assoc-default "foo.nix" auto-mode-alist #'string-match-p))))

(ert-deftest nix-mode-test-auto-mode-flake-lock ()
  "A flake.lock file maps to `js-json-mode'."
  (should (eq 'js-json-mode
              (assoc-default "/path/flake.lock" auto-mode-alist
                             #'string-match-p))))

(provide 'nix-test-mode)
;;; nix-test-mode.el ends here
