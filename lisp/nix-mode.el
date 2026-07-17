;;; nix-mode.el --- Major mode for the Nix language  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Thanos Apollo

;; Author: Thanos Apollo <public@thanosapollo.org>
;; Maintainer: Thanos Apollo <public@thanosapollo.org>
;; Keywords: languages
;; URL: https://codeberg.org/thanosapollo/emacs-nix-mode
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (keymap-popup "0.3"))

;; This file is a part of nix-mode.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; A tree-sitter major mode for the Nix expression language, plus the
;; entry point for the wider nix-mode tooling suite (see the sibling
;; nix-core, nix-repl and nix-flake modules).
;;
;; The mode is tree-sitter only: it needs the nix-community grammar
;; <https://github.com/nix-community/tree-sitter-nix>.  When the grammar
;; is missing the mode refuses to start and points you at
;; \\[nix-mode-install-grammar], which downloads and compiles it via the
;; standard `treesit-install-language-grammar' machinery.
;;
;; Font-lock, indentation, imenu and structural navigation are all
;; derived from the parse tree; there is no regexp fallback engine.

;;; Code:

(require 'treesit)
(require 'nix-core)
(require 'keymap-popup)
(eval-when-compile (require 'rx))

(declare-function treesit-parent-until "treesit")
(declare-function treesit-install-language-grammar "treesit")
(declare-function sh-set-shell "sh-script")
(declare-function nix-build "nix-commands")
(declare-function nix-search "nix-commands")
(declare-function nix-edit "nix-commands")
(declare-function nix-log "nix-commands")
(declare-function nix-flake "nix-flake")
(declare-function nix-repl "nix-repl")

;;; Customization

(defcustom nix-indent-offset 2
  "Number of spaces for each indentation step in `nix-mode'."
  :type 'natnum
  :safe #'natnump
  :group 'nix)

;;; Faces

;; Nix maps cleanly onto the standard font-lock faces, so the only face
;; worth minting is one for string interpolation: the antiquote `${...}'
;; delimiters read best when set apart from the surrounding string.

(defface nix-interpolation-face
  '((t :inherit font-lock-misc-punctuation-face))
  "Face for the `${' and `}' antiquote delimiters inside Nix strings."
  :group 'nix)

;;; Grammar

(add-to-list 'treesit-language-source-alist
             '(nix "https://github.com/nix-community/tree-sitter-nix"))

;;;###autoload
(defun nix-mode-install-grammar ()
  "Install the tree-sitter grammar for Nix.
Downloads and compiles the grammar registered on
`treesit-language-source-alist' via
`treesit-install-language-grammar'."
  (interactive)
  (treesit-install-language-grammar 'nix))

(defconst nix-mode--builtins
  '("abort" "add" "addErrorContext" "all" "any" "attrNames" "attrValues"
    "baseNameOf" "bitAnd" "bitOr" "bitXor" "builtins" "catAttrs" "ceil"
    "compareVersions" "concatLists" "concatMap" "concatStringsSep"
    "currentSystem" "currentTime" "deepSeq" "derivation" "derivationStrict"
    "dirOf" "div" "elem" "elemAt" "false" "fetchGit" "fetchMercurial"
    "fetchTarball" "fetchTree" "fetchurl" "filter" "filterSource"
    "floor" "foldl'" "fromJSON" "fromTOML" "functionArgs" "genList"
    "genericClosure" "getAttr" "getEnv" "getFlake" "groupBy" "hasAttr"
    "hasContext" "hashFile" "hashString" "head" "import" "intersectAttrs"
    "isAttrs" "isBool" "isFloat" "isFunction" "isInt" "isList" "isNull"
    "isPath" "isString" "length" "lessThan" "listToAttrs" "map" "mapAttrs"
    "match" "mul" "null" "parseDrvName" "partition" "path" "pathExists"
    "placeholder" "readDir" "readFile" "removeAttrs" "replaceStrings"
    "scopedImport" "seq" "sort" "split" "splitVersion" "storePath"
    "stringLength" "sub" "substring" "tail" "throw" "toFile" "toJSON"
    "toPath" "toString" "toXML" "trace" "true" "tryEval" "typeOf"
    "unsafeDiscardStringContext" "unsafeGetAttrPos" "zipAttrsWith")
  "Nix built-in identifiers highlighted with `font-lock-builtin-face'.")

;;; Font-lock

(defvar nix-mode--font-lock-settings
  (treesit-font-lock-rules
   :language 'nix
   :feature 'comment
   '((comment) @font-lock-comment-face)

   :language 'nix
   :feature 'definition
   '((binding attrpath: (attrpath (identifier) @font-lock-variable-name-face))
     (formal name: (identifier) @font-lock-variable-name-face)
     (inherit attrs: (inherited_attrs (identifier)
				      @font-lock-variable-name-face)))

   :language 'nix
   :feature 'keyword
   '(["let" "in" "rec" "if" "then" "else" "with" "assert" "inherit" "or"]
     @font-lock-keyword-face)

   ;; Fontify only the literal string parts -- the `"'/`''' delimiters and
   ;; the `string_fragment' runs -- so code inside `${...}' interpolations
   ;; keeps its normal fontification (variables, builtins, numbers, ...).
   :language 'nix
   :feature 'string
   '((string_fragment) @font-lock-string-face
     (string_expression ["\""] @font-lock-string-face)
     (indented_string_expression ["''"] @font-lock-string-face))

   :language 'nix
   :feature 'builtin
   `(((variable_expression name: (identifier) @font-lock-builtin-face)
      (:match ,(rx-to-string `(seq bos (or ,@nix-mode--builtins) eos) t)
              @font-lock-builtin-face)))

   :language 'nix
   :feature 'escape
   :override t
   '((escape_sequence) @font-lock-escape-face
     (dollar_escape) @font-lock-escape-face)

   :language 'nix
   :feature 'number
   '((integer_expression) @font-lock-number-face
     (float_expression) @font-lock-number-face)

   :language 'nix
   :feature 'path
   '((path_expression) @font-lock-constant-face
     (hpath_expression) @font-lock-constant-face
     (spath_expression) @font-lock-constant-face
     (uri_expression) @font-lock-constant-face)

   :language 'nix
   :feature 'interpolation
   :override t
   '((interpolation ["${" "}"] @nix-interpolation-face))

   :language 'nix
   :feature 'function
   '((apply_expression
      function: (variable_expression name: (identifier)
				     @font-lock-function-call-face)))

   :language 'nix
   :feature 'parameter
   '((formal name: (identifier) @font-lock-variable-name-face))

   :language 'nix
   :feature 'operator
   '((binary_expression operator: _ @font-lock-operator-face)
     (unary_expression operator: _ @font-lock-operator-face)
     (has_attr_expression operator: _ @font-lock-operator-face))

   :language 'nix
   :feature 'bracket
   '((["(" ")" "[" "]" "{" "}"]) @font-lock-bracket-face)

   :language 'nix
   :feature 'delimiter
   '((["." ";" "," ":" "=" "@" "?"]) @font-lock-delimiter-face)

   :language 'nix
   :feature 'error
   :override t
   '((ERROR) @font-lock-warning-face))
  "Tree-sitter font-lock settings for `nix-mode'.")

;;; Indentation

;; The node that starts a line is often a deep leaf (the `identifier' of
;; a binding's attrpath, an anonymous `inherit' keyword), so matching the
;; immediate `parent-is' misses the enclosing block.  `nix-mode--ancestor-is'
;; climbs the tree to the nearest node of a given type and both matches and
;; anchors on it, which is what keeps bindings and list elements aligned.

(defun nix-mode--ancestor (node type)
  "Return the nearest ancestor of NODE whose type is TYPE, or nil.
NODE itself is considered."
  (treesit-parent-until
   node (lambda (n) (equal (treesit-node-type n) type)) t))

(defun nix-mode--ancestor-is (type)
  "Return an indent matcher true when an ancestor has type TYPE."
  (lambda (node _parent _bol &rest _)
    (and (nix-mode--ancestor node type) t)))

(defun nix-mode--ancestor-bol (type)
  "Return an indent anchor at the bol of the nearest TYPE ancestor."
  (lambda (node parent _bol &rest _)
    (let ((anchor (or (nix-mode--ancestor node type)
                      (nix-mode--ancestor parent type))))
      (save-excursion
        (goto-char (treesit-node-start anchor))
        (back-to-indentation)
        (point)))))

(defun nix-mode--enclosing-block-bol (node type)
  "Return the bol of the line opening the nearest TYPE ancestor of NODE.
A binding set's range starts at its first binding rather than the
brace, so anchor on its parent (the attrset or let opener) to keep
sibling bindings aligned regardless of nesting depth."
  (let* ((block (nix-mode--ancestor node type))
         (opener (treesit-node-parent block)))
    (save-excursion
      (goto-char (treesit-node-start (or opener block)))
      (back-to-indentation)
      (point))))

(defun nix-mode--field-of (type field)
  "Return a matcher true when NODE fills FIELD of a TYPE parent."
  (lambda (node parent _bol &rest _)
    (and (equal (treesit-node-type parent) type)
         (treesit-node-eq
          node (treesit-node-child-by-field-name parent field)))))

(defun nix-mode--field-body-of (type)
  "Return a matcher true when the node fills the `body' field of TYPE."
  (nix-mode--field-of type "body"))

(defconst nix-mode--string-node-types
  '("string_fragment" "indented_string_expression" "string_expression")
  "Node types whose interior lines keep their original indentation.")

(defun nix-mode--in-string-p (node parent &rest _)
  "Non-nil when NODE or PARENT lies inside a string body.
Lines here keep their own indentation so multi-line string content
survives `indent-region' verbatim."
  (or (member (treesit-node-type node) nix-mode--string-node-types)
      (member (treesit-node-type parent) nix-mode--string-node-types)))

(defun nix-mode--keep-indent-anchor (_node _parent bol &rest _)
  "Return BOL, the first non-blank position, as the indent anchor.
Its column is the line's current indentation, so pairing this with
a zero offset leaves the line exactly where the user put it."
  bol)

(defun nix-mode--indent-rules ()
  "Return the tree-sitter indent rules for `nix-mode'."
  ;; `node-is' and `parent-is' match the type as an unanchored regexp, so
  ;; every literal below is wrapped in `\\`...\\'' to avoid spurious hits
  ;; (a bare "in" otherwise matches inside "binding_set").
  `((nix
     ;; Leave multi-line string content exactly as the user wrote it.
     (nix-mode--in-string-p nix-mode--keep-indent-anchor 0)
     ;; A closing delimiter lines up with the line its opener sits on.
     ((node-is "\\`}\\'") standalone-parent 0)
     ((node-is "\\`]\\'") standalone-parent 0)
     ((node-is "\\`)\\'") standalone-parent 0)
     ;; `in' and the let body return to the `let' column; nixpkgs keeps
     ;; the body flush with `let' rather than indenting under `in'.
     ((node-is "\\`in\\'") ,(nix-mode--ancestor-bol "let_expression") 0)
     (,(nix-mode--field-body-of "let_expression")
      ,(nix-mode--ancestor-bol "let_expression") 0)
     ;; if/then/else keywords align with `if'; the branches indent one
     ;; step under it.
     ((node-is "\\`then\\'") ,(nix-mode--ancestor-bol "if_expression") 0)
     ((node-is "\\`else\\'") ,(nix-mode--ancestor-bol "if_expression") 0)
     ((field-is "consequence")
      ,(nix-mode--ancestor-bol "if_expression") ,nix-indent-offset)
     ((field-is "alternative")
      ,(nix-mode--ancestor-bol "if_expression") ,nix-indent-offset)
     ;; A binding value that wraps onto its own line indents under the
     ;; binding (nixfmt style), so match it before the generic set rule.
     (,(nix-mode--field-of "binding" "expression")
      parent-bol ,nix-indent-offset)
     ;; Wrapped `inherit' attributes and the trailing `;' indent under the
     ;; inherit keyword.  The first attribute's line starts at the whole
     ;; `inherited_attrs' node, later ones at a bare identifier, so match
     ;; both shapes.
     ((parent-is "\\`inherit\\'")
      ,(nix-mode--ancestor-bol "inherit") ,nix-indent-offset)
     ((parent-is "\\`inherit_from\\'")
      ,(nix-mode--ancestor-bol "inherit_from") ,nix-indent-offset)
     ((n-p-gp nil "\\`inherited_attrs\\'" "\\`inherit\\'")
      ,(nix-mode--ancestor-bol "inherit") ,nix-indent-offset)
     ((n-p-gp nil "\\`inherited_attrs\\'" "\\`inherit_from\\'")
      ,(nix-mode--ancestor-bol "inherit_from") ,nix-indent-offset)
     ;; A lambda body aligns with the lambda's own line, whether the
     ;; lambda is a file-level function or a nested binding value.  This
     ;; matches nixfmt: `f =\n  { ... }:\n  body' keeps params and body
     ;; at the same column.
     (,(nix-mode--field-body-of "function_expression") parent-bol 0)
     ;; List elements and the continuation of applications, selects and
     ;; binary operators, anchored on the standalone parent so long chains
     ;; do not stair-step.  These come before the generic set rule because
     ;; their contents also live inside a binding set.
     ((parent-is "\\`list_expression\\'") standalone-parent ,nix-indent-offset)
     ((parent-is "\\`apply_expression\\'") standalone-parent ,nix-indent-offset)
     ;; nixfmt aligns a wrapped binary operator flush with its left
     ;; operand rather than indenting it a further step.
     ((parent-is "\\`binary_expression\\'") standalone-parent 0)
     ((parent-is "\\`select_expression\\'") standalone-parent ,nix-indent-offset)
     ((parent-is "\\`parenthesized_expression\\'")
      standalone-parent ,nix-indent-offset)
     ((parent-is "\\`with_expression\\'") parent-bol 0)
     ((parent-is "\\`assert_expression\\'") parent-bol 0)
     ;; Bindings inside every attrset flavour and formal parameters, keyed
     ;; on the enclosing set so deep leaves still line up.
     (,(nix-mode--ancestor-is "binding_set")
      ,(lambda (node &rest _)
         (nix-mode--enclosing-block-bol node "binding_set"))
      ,nix-indent-offset)
     (,(nix-mode--ancestor-is "formals")
      ,(lambda (node &rest _)
         (nix-mode--enclosing-block-bol node "formals"))
      ,nix-indent-offset)
     (catch-all parent-bol 0))))

;;; Navigation and imenu

(defconst nix-mode--defun-type-regexp
  (rx bos (or "binding" "function_expression") eos)
  "Regexp matching the node types treated as Nix defuns.")

(defun nix-mode--defun-name (node)
  "Return the defun name of NODE, or nil.
For a binding this is the dotted attribute path; anonymous
functions have no name."
  (when (equal (treesit-node-type node) "binding")
    (let ((attrpath (treesit-node-child-by-field-name node "attrpath")))
      (and attrpath (treesit-node-text attrpath t)))))

;;; Syntax table

(defvar nix-mode--syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?# "<" table)
    (modify-syntax-entry ?\n ">" table)
    (modify-syntax-entry ?/ ". 14" table)
    (modify-syntax-entry ?* ". 23" table)
    (modify-syntax-entry ?\" "\"" table)
    (modify-syntax-entry ?_ "_" table)
    (modify-syntax-entry ?- "_" table)
    (modify-syntax-entry ?' "." table)
    table)
  "Syntax table for `nix-mode'.")

;;; Mode definition

;; The sibling commands bound below carry autoload cookies, so binding
;; them by symbol pulls no module at load time; each is loaded on first
;; keypress.  C-c C-<letter> is reserved for major modes.
(defvar-keymap nix-mode-map
  :doc "Keymap for `nix-mode'."
  "C-c C-b" #'nix-build
  "C-c C-f" #'nix-flake
  "C-c C-z" #'nix-repl
  "C-c C-e" #'nix-edit
  "C-c C-s" #'nix-search
  "C-c C-l" #'nix-log
  "C-c '" #'nix-format-buffer)

;; keymap-popup is a hard dependency, so annotate directly rather than
;; through `with-eval-after-load'.  Keys resolve via `where-is-internal'
;; at display time, so the popup follows any user rebinding.
(keymap-popup-annotate nix-mode-map
  :group "Build"
  nix-build "Build derivation"
  nix-flake "Flake menu"
  nix-repl "REPL"
  :group "Browse"
  nix-search "Search packages"
  nix-edit "Edit package source"
  nix-log "Build log"
  :group "Buffer"
  nix-format-buffer "Format buffer")

(defun nix-mode--setup-things ()
  "Install Emacs 30 `treesit-thing-settings' when supported."
  (when (boundp 'treesit-thing-settings)
    (setq-local treesit-thing-settings
                `((nix
                   (sexp (not ,(rx bos (or "source_code" "comment") eos)))
                   (sentence ,(rx bos (or "binding" "inherit"
                                          "inherit_from")
                                  eos))
                   (text ,(rx bos (or "comment" "string_fragment") eos)))))))

;;;###autoload
(define-derived-mode nix-mode prog-mode "Nix"
  "Major mode for editing Nix expressions, powered by tree-sitter.

\\{nix-mode-map}"
  :group 'nix
  :syntax-table nix-mode--syntax-table
  (unless (treesit-ready-p 'nix t)
    (user-error
     "Tree-sitter grammar for Nix missing; run M-x nix-mode-install-grammar"))
  (treesit-parser-create 'nix)

  ;; Comments.
  (setq-local comment-start "# ")
  (setq-local comment-end "")
  (setq-local comment-start-skip (rx (or "#" "/*") (* (syntax whitespace))))

  ;; Indentation with spaces, two per step.
  (setq-local indent-tabs-mode nil)
  (setq-local tab-width nix-indent-offset)
  (setq-local treesit-simple-indent-rules (nix-mode--indent-rules))

  ;; Font-lock.
  (setq-local treesit-font-lock-settings nix-mode--font-lock-settings)
  (setq-local treesit-font-lock-feature-list
              '((comment definition)
                (keyword string builtin escape)
                (number path interpolation function parameter)
                (operator bracket delimiter error)))

  ;; Navigation and imenu.
  (setq-local treesit-defun-type-regexp nix-mode--defun-type-regexp)
  (setq-local treesit-defun-name-function #'nix-mode--defun-name)
  (setq-local treesit-simple-imenu-settings
              '(("Binding" "\\`binding\\'" nil nil)))
  (nix-mode--setup-things)

  (treesit-major-mode-setup))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.nix\\'" . nix-mode))
;;;###autoload
(add-to-list 'auto-mode-alist '("/flake\\.lock\\'" . js-json-mode))

;;; Formatting

;; Formatting is deliberately a thin wrapper over an external tool:
;; `nix-formatter' is a program-plus-arguments list so a user can switch
;; between nixfmt, alejandra or nixpkgs-fmt purely by customization.  The
;; buffer edit goes through `replace-buffer-contents', which preserves
;; point and markers by diffing rather than wholesale replacing the text.

(defcustom nix-formatter '("nixfmt" "-")
  "Program and arguments used to format Nix buffers.
The first element is the executable and the rest are extra
arguments; the buffer contents are fed on standard input and the
formatted result read from standard output.  The default passes
nixfmt the \"-\" argument that selects anonymous stdin.  Point at,
say, alejandra or nixpkgs-fmt by customizing this list."
  :type '(repeat string)
  :group 'nix)

(defun nix-format--program ()
  "Return the absolute path to the configured formatter executable.
Signal a `user-error' when `nix-formatter' is empty or its
program cannot be found via `executable-find'."
  (let ((program (car nix-formatter)))
    (or (and program (executable-find program))
        (user-error "Cannot find Nix formatter %S"
                    (or program nix-formatter)))))

;;;###autoload
(defun nix-format-buffer ()
  "Format the current buffer with `nix-formatter'.
Run the formatter with the buffer contents on standard input and,
on a successful exit, splice the output back in with
`replace-buffer-contents' so point and markers survive.  On
failure signal a `user-error' and show the formatter output in
the *nix-format* buffer."
  (interactive)
  (let ((program (nix-format--program))
        (args (cdr nix-formatter))
        (source (current-buffer))
        (out (get-buffer-create "*nix-format*")))
    (with-current-buffer out (erase-buffer))
    (if (zerop (apply #'call-process-region nil nil program
                      nil out nil args))
        (progn
          (replace-buffer-contents out)
          (kill-buffer out))
      (with-current-buffer source (pop-to-buffer out))
      (user-error "Nix formatter failed; see the *nix-format* buffer"))))

;;;###autoload
(define-minor-mode nix-format-on-save-mode
  "Format the buffer with `nix-format-buffer' before every save.
Enable it per buffer, typically from `nix-mode-hook':

  (add-hook \\='nix-mode-hook \\='nix-format-on-save-mode)"
  :lighter nil
  (if nix-format-on-save-mode
      (add-hook 'before-save-hook #'nix-format-buffer nil t)
    (remove-hook 'before-save-hook #'nix-format-buffer t)))

;;; Shebang detection

;; Nix shell scripts open with a two-line shebang:
;;
;;   #!/usr/bin/env nix-shell
;;   #! nix-shell -i bash -p hello
;;
;; The real interpreter is the argument to `-i' on the `nix-shell' line,
;; which may carry other flags (`-p', packages) in any order.  We match
;; on the buffer start and hand off to whatever mode
;; `interpreter-mode-alist' assigns that interpreter.

(defconst nix-mode--shebang-regexp
  (rx-let ((hspace (any " \t"))
           (path-command
            (seq "/" (* (seq (+ (not (any "/ \t\n"))) "/")) "nix-shell"))
           (env-path
            (seq "/" (* (seq (+ (not (any "/ \t\n"))) "/")) "env"))
           (env-command
            (seq env-path (+ hspace)
                 (? (seq "-S" (+ hspace))) "nix-shell"))
           (command (or "nix-shell" path-command env-command))
           (interpreter
            (seq (+ hspace)
                 (or "-i" (seq (+ nonl) (+ hspace) "-i"))
                 (+ hspace) (group (+ (not (any " \t\n")))))))
    (rx (seq (or (seq bol "#!" (* hspace) command)
                     (seq bol "#!" (* hspace) command (* nonl) "\n"
                          "#!" (* hspace) command))
             interpreter)))
  "Regexp capturing the interpreter of a nix-shell shebang line.")

(defconst nix-mode--shebang-magic-regexp
  (concat "\\`" nix-mode--shebang-regexp)
  "Regexp for `magic-mode-alist' matching a nix-shell shebang.
It is anchored at the buffer start and bounded to the first two
lines so magic matching stays cheap.  It matches both the
single-line form and the two-line `env nix-shell' form, requiring
`nix-shell' and its `-i' flag on the same physical line.  The
`magic-mode-alist' entry below inlines this same regexp as a
literal so the autoloads file stays pure data; keep them in sync.")

(defun nix-mode--shebang-interpreter ()
  "Return the interpreter of the nix-shell shebang, or nil.
Scan the first two lines of the current buffer for a
`nix-shell -i INTERP' directive and return INTERP."
  (save-excursion
    (goto-char (point-min))
    (and (re-search-forward nix-mode--shebang-regexp
                            (line-beginning-position 3) t)
         (match-string 1))))

(defun nix-mode--interpreter-mode (interpreter)
  "Return the major-mode function bound to INTERPRETER, or nil.
Look INTERPRETER up in `interpreter-mode-alist', anchoring each
alist key so it must match INTERPRETER exactly.  Mirrors the
interpreter branch of `set-auto-mode-0' in files.el, avoiding
substring hits like key \"sh\" claiming \"fish\"."
  (assoc-default interpreter
                 (mapcar (lambda (e) (cons (format "\\`%s\\'" (car e)) (cdr e)))
                         interpreter-mode-alist)
                 #'string-match-p))

;;;###autoload
(defun nix-shebang-mode ()
  "Enter the major mode implied by a nix-shell shebang.
Meant for `magic-mode-alist': when the buffer opens with a
nix-shell shebang naming an interpreter that
`interpreter-mode-alist' knows, switch to that mode.  Configure
`sh-mode' variants from that interpreter rather than the outer
nix-shell shebang.  Do nothing
for an unknown or absent interpreter so magic matching declines
gracefully."
  (when-let* ((interpreter (nix-mode--shebang-interpreter))
              (mode (nix-mode--interpreter-mode interpreter)))
    (funcall mode)
    (when (derived-mode-p 'sh-mode)
      (sh-set-shell interpreter t nil))))

;; The `magic-mode-alist' key is a plain regexp, not a function, so the
;; entry is pure data in the autoloads file: `find-file' can consult it
;; before nix-mode has loaded without executing any of our code.  The
;; regexp is the literal expansion of `nix-mode--shebang-magic-regexp'
;; (inlined so the autoloads file needs no private symbol); keep the two
;; in sync.  It only claims buffers that open with a genuine nix-shell
;; shebang; `nix-shebang-mode' (autoloaded) then re-extracts the
;; interpreter and declines gracefully when it is unknown or absent.
;;;###autoload
(add-to-list 'magic-mode-alist
             '("\\`\\(?:^#![\t ]*\\(?:nix-shell\\|/\\(?:[^\t\n /]+/\\)*nix-shell\\|/\\(?:[^\t\n /]+/\\)*env[\t ]+\\(?:-S[\t ]+\\)?nix-shell\\)\\|^#![\t ]*\\(?:nix-shell\\|/\\(?:[^\t\n /]+/\\)*nix-shell\\|/\\(?:[^\t\n /]+/\\)*env[\t ]+\\(?:-S[\t ]+\\)?nix-shell\\).*\n#![\t ]*\\(?:nix-shell\\|/\\(?:[^\t\n /]+/\\)*nix-shell\\|/\\(?:[^\t\n /]+/\\)*env[\t ]+\\(?:-S[\t ]+\\)?nix-shell\\)\\)[\t ]+\\(?:-i\\|.+[\t ]+-i\\)[\t ]+\\([^\t\n ]+\\)"
               . nix-shebang-mode))

(provide 'nix-mode)
;;; nix-mode.el ends here
