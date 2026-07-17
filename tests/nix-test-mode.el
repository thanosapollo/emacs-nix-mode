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

;;; Group 6: formatting

;; These exercise the real formatter from the devshell.  The success
;; tests assert stable properties (idempotence, point preservation)
;; rather than a byte-exact expected string, so they survive nixfmt
;; version bumps.

(defconst nix-mode-test--misformatted "{a=1;b=2;}\n"
  "A snippet nixfmt will reflow, used by the formatter tests.")

(defun nix-mode-test--nixfmt-available-p ()
  "Return non-nil when the configured formatter is on the exec path."
  (and (executable-find (car nix-formatter)) t))

(ert-deftest nix-mode-test-format-buffer-is-idempotent ()
  "Formatting an already-formatted buffer changes nothing."
  (skip-unless (nix-mode-test--nixfmt-available-p))
  (with-temp-buffer
    (insert nix-mode-test--misformatted)
    (nix-format-buffer)
    (let ((formatted (buffer-string)))
      (nix-format-buffer)
      (should (string-equal formatted (buffer-string))))))

(ert-deftest nix-mode-test-format-buffer-preserves-point ()
  "Formatting keeps point on the same binding via marker preservation."
  (skip-unless (nix-mode-test--nixfmt-available-p))
  (with-temp-buffer
    (insert nix-mode-test--misformatted)
    (goto-char (point-min))
    (search-forward "b")
    (let ((marker (point-marker)))
      (nix-format-buffer)
      (goto-char marker)
      (should (looking-back "b" (line-beginning-position))))))

(ert-deftest nix-mode-test-format-buffer-signals-on-failure ()
  "A failing formatter signals a `user-error'."
  (let ((nix-formatter '("false")))
    (skip-unless (executable-find "false"))
    (with-temp-buffer
      (insert "{ a = 1; }\n")
      (should-error (nix-format-buffer) :type 'user-error))))

(ert-deftest nix-mode-test-format-on-save-mode-toggles-hook ()
  "The on-save mode adds and removes the local `before-save-hook'."
  (with-temp-buffer
    (nix-format-on-save-mode 1)
    (should (memq #'nix-format-buffer
                  (buffer-local-value 'before-save-hook (current-buffer))))
    (nix-format-on-save-mode -1)
    (should-not (memq #'nix-format-buffer
                      (buffer-local-value 'before-save-hook
                                          (current-buffer))))))

;;; Group 7: shebang detection

(defconst nix-mode-test--shebang-scripts
  '(("interp-present" . "#!/usr/bin/env nix-shell\n#! nix-shell -i bash -p hello\necho hi\n")
    ("extra-p-args" . "#!/usr/bin/env nix-shell\n#! nix-shell -p hello python3 -i python3\nprint()\n")
    ("no-shebang" . "{ a = 1; }\n")
    ("shell-without-i" . "#!/usr/bin/env nix-shell\n#! nix-shell -p hello\n"))
  "Fixtures for the shebang interpreter extractor.")

(defun nix-mode-test--interp-of (name)
  "Return the extracted interpreter for fixture NAME."
  (with-temp-buffer
    (insert (assoc-default name nix-mode-test--shebang-scripts))
    (nix-mode--shebang-interpreter)))

(ert-deftest nix-mode-test-shebang-extracts-interpreter ()
  "The extractor finds the -i interpreter, ignoring order of flags."
  (should (equal "bash" (nix-mode-test--interp-of "interp-present")))
  (should (equal "python3" (nix-mode-test--interp-of "extra-p-args"))))

(ert-deftest nix-mode-test-shebang-absent-returns-nil ()
  "No nix-shell -i line yields nil."
  (should-not (nix-mode-test--interp-of "no-shebang"))
  (should-not (nix-mode-test--interp-of "shell-without-i")))

(ert-deftest nix-mode-test-shebang-mode-dispatches-to-interpreter ()
  "`nix-shebang-mode' enters the mode `interpreter-mode-alist' gives bash."
  (with-temp-buffer
    (insert (assoc-default "interp-present" nix-mode-test--shebang-scripts))
    (nix-shebang-mode)
    (should (eq major-mode
                (nix-mode--interpreter-mode "bash")))))

(ert-deftest nix-mode-test-shebang-mode-dispatches-single-line-env ()
  "A single-line env nix-shell shebang dispatches to its interpreter mode."
  (with-temp-buffer
    (insert "#!/usr/bin/env nix-shell -i bash -p hello\n")
    (nix-shebang-mode)
    (should (eq major-mode
                (nix-mode--interpreter-mode "bash")))))

(ert-deftest nix-mode-test-shebang-mode-declines-unknown ()
  "`nix-shebang-mode' does nothing when there is no nix-shell shebang."
  (with-temp-buffer
    (insert (assoc-default "no-shebang" nix-mode-test--shebang-scripts))
    (let ((before major-mode))
      (nix-shebang-mode)
      (should (eq major-mode before)))))

(ert-deftest nix-mode-test-shebang-magic-regexp-matches ()
  "The `magic-mode-alist' regexp claims real nix-shell shebangs."
  (dolist (content '("#!/usr/bin/env nix-shell\n#! nix-shell -i bash -p hello\n"
                     "#!/usr/bin/env nix-shell -i bash -p hello\n"))
    (should (string-match-p nix-mode--shebang-magic-regexp content))))

(ert-deftest nix-mode-test-shebang-magic-regexp-declines ()
  "The `magic-mode-alist' regexp ignores non-nix-shell buffers.
It must not match plain Nix files, ordinary shebang scripts, or a
buffer whose nix-shell line only appears past the first two lines."
  (dolist (content '("{ a = 1; }\n"
                     "#!/usr/bin/env bash\necho hi\n"
                     "#!/usr/bin/env nix-shell\n#! nix-shell -p foo-i bash\n"
                     "#!/usr/bin/env bash\n# comment\n#! nix-shell -i bash\n"))
    (should-not (string-match-p nix-mode--shebang-magic-regexp content))))

(ert-deftest nix-mode-test-shebang-requires-distinct-interpreter-option ()
  "A package token ending in -i is not an interpreter option."
  (with-temp-buffer
    (insert "#!/usr/bin/env nix-shell\n#! nix-shell -p foo-i bash\n")
    (should-not (nix-mode--shebang-interpreter))
    (let ((before major-mode))
      (nix-shebang-mode)
      (should (eq major-mode before)))))

(ert-deftest nix-mode-test-shebang-rejects-option-on-plain-second-line ()
  "Magic dispatch does not join a plain second line to the shebang."
  (with-temp-buffer
    (setq buffer-file-name "/tmp/nix-mode-malformed-script")
    (insert "#!/usr/bin/env nix-shell\n-i bash\n")
    (set-auto-mode)
    (should (eq major-mode 'fundamental-mode))))

(ert-deftest nix-mode-test-shebang-magic-alist-literal-in-sync ()
  "The inlined `magic-mode-alist' regexp equals the defconst.
The autoloaded entry hardcodes the regexp as pure data; this
guards against it drifting from `nix-mode--shebang-magic-regexp'."
  (should (equal nix-mode--shebang-magic-regexp
                 (car (rassq 'nix-shebang-mode magic-mode-alist)))))

(ert-deftest nix-mode-test-interpreter-mode-no-substring-match ()
  "An interpreter with no exact alist entry does not borrow a substring's mode.
\"fish\" contains \"sh\" but must not resolve to a mode via the
\"sh\" alist key."
  (let ((interpreter-mode-alist '(("bash" . sh-mode) ("sh" . sh-mode))))
    (should (eq 'sh-mode (nix-mode--interpreter-mode "bash")))
    (should-not (nix-mode--interpreter-mode "fish"))))

(ert-deftest nix-mode-test-emacs-29-does-not-create-primary-parser-variable ()
  "Starting `nix-mode' on Emacs 29 does not create a free global variable."
  (skip-unless (= emacs-major-version 29))
  (skip-unless (treesit-ready-p 'nix t))
  (should-not (boundp 'treesit-primary-parser))
  (with-temp-buffer (nix-mode))
  (should-not (boundp 'treesit-primary-parser)))

(provide 'nix-test-mode)
;;; nix-test-mode.el ends here
