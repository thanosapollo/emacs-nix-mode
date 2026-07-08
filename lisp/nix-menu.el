;;; nix-menu.el --- Top-level command menu for nix-mode  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Thanos Apollo

;; Maintainer: Thanos Apollo <public@thanosapollo.org>

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

;; A single global entry point, `nix-menu', that gathers the command
;; surface of the sibling modules into one keymap-popup.  It is the
;; only place the modules meet, and it meets them lazily: every entry
;; names an autoloaded command by symbol, so pressing a key loads that
;; module on demand and nothing is required here beyond keymap-popup
;; itself.  This keeps the module graph acyclic -- nix-menu depends on
;; no feature module, and no feature module depends on nix-menu.
;;
;; The flake entry is the command `nix-flake' rather than a :keymap
;; reference to `nix-flake-menu-map': the command carries an autoload,
;; so it loads nix-flake on first use, whereas a bare :keymap target
;; would reference an unbound variable until nix-flake happened to be
;; loaded by other means.

;;; Code:

(require 'keymap-popup)

(declare-function nix-build "nix-commands")
(declare-function nix-search "nix-commands")
(declare-function nix-edit "nix-commands")
(declare-function nix-log "nix-commands")
(declare-function nix-shell "nix-shell")
(declare-function nix-eshell "nix-shell")
(declare-function nix-flake "nix-flake")
(declare-function nix-repl "nix-repl")
(declare-function nix-store-show-path "nix-store")
(declare-function nix-format-buffer "nix-mode")

;; Forward-declared for byte-compilers that emit the launcher `defun'
;; ahead of the `defvar-keymap', matching the pattern in nix-flake.el.
(defvar nix-menu-map)

(keymap-popup-define nix-menu-map
  "Top-level Nix commands."
  :group "Build"
  "b" ("Build" nix-build)
  "s" ("Shell environment" nix-shell)
  "e" ("Eshell" nix-eshell)
  :group "Flakes"
  "f" ("Flake menu" nix-flake)
  :group "Browse"
  "r" ("REPL" nix-repl)
  "/" ("Search packages" nix-search)
  "p" ("Store path" nix-store-show-path)
  "o" ("Open package source" nix-edit)
  "l" ("Build log" nix-log)
  :group "Buffer"
  "=" ("Format buffer" nix-format-buffer
       :if (lambda () (derived-mode-p 'nix-mode))))

;;;###autoload
(defun nix-menu ()
  "Open the top-level Nix command menu."
  (interactive)
  (keymap-popup nix-menu-map))

(provide 'nix-menu)
;;; nix-menu.el ends here
