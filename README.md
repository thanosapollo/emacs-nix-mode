# nix-mode

A tree-sitter Emacs major mode for the [Nix](https://nixos.org) language,
plus a small suite of tooling around the `nix` command line.  It is a
clean-room rewrite of the unmaintained nix-mode: same feature surface,
modern internals.

Requires Emacs 29.1 or later, built with tree-sitter support.  The mode is
tree-sitter only -- there is no regexp fallback engine -- so it needs the
[nix-community grammar](https://github.com/nix-community/tree-sitter-nix).

## Features

- Major mode with font-lock, indentation, imenu and structural navigation
  all derived from the parse tree.
- Buffer formatting through an external formatter (`nixfmt` by default,
  `alejandra` or `nixpkgs-fmt` by customization), with an optional
  format-on-save minor mode.
- A `nix repl` comint buffer with completion at point.
- A flake UI (`nix flake` run, build, check, lock, update, init, plus the
  registry) presented through [keymap-popup](https://codeberg.org/thanosapollo/emacs-keymap-popup)
  instead of transient.
- A store browser: a read-only, outline-folded, button-linked view of a
  store path and its references, deriver and requisites.
- Ad-hoc shell environments (`nix-shell`, `nix-shell-with-packages`) and an
  eshell integration that runs a buffer inside the environment.
- `nix-prettify-mode` (and a global variant) that abbreviates
  `/nix/store/<hash>-` prefixes in any buffer.
- Package search, build, build-log and source-edit commands over the
  `nix` CLI.

## Installation

The package is not on ELPA or MELPA yet.  Clone it and put `lisp/` on your
`load-path`, or install from source with `package-vc` on Emacs 30+:

```elisp
(package-vc-install "https://codeberg.org/thanosapollo/nix-mode")
```

Then install the tree-sitter grammar once:

```
M-x nix-mode-install-grammar
```

This downloads and compiles the grammar via the standard
`treesit-install-language-grammar` machinery.  nix-mode registers the
grammar source on `treesit-language-source-alist` when it loads, so no
manual `treesit-language-source-alist` entry is required.

## Quick start

Opening any `.nix` file activates `nix-mode` automatically.  From there:

- `C-c C-f` opens the flake menu for the current buffer.
- `C-c C-b` builds, `C-c C-z` opens the REPL, `C-c C-s` searches,
  `C-c C-e` edits a package source, `C-c C-l` shows a build log, and
  `C-c '` formats the buffer.
- `M-x nix-menu` opens a top-level popup with the same commands, usable
  from any buffer.

Every command loads its module on first use, so startup cost is just the
mode itself.

## Development

Everything runs through the project flake, which provides Emacs, the
grammar and all lint tools:

```
nix develop
make dev        # autoloads + byte-compile + lint + tests
make test       # tests only
make lint       # check-declare, checkdoc, package-lint, relint
```

`nix flake check` runs the full test matrix (interactive and batch,
one-shot and repeated) in a sandbox.
