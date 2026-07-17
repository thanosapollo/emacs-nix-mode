;;; nix-flake.el --- Flake interface for nix-mode  -*- lexical-binding: t; -*-

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

;; A keymap-popup interface to the experimental "nix flake" commands,
;; ported from the transient-based nix-flake.el of the unmaintained
;; nix-mode.  The command surface is preserved; the internals are not.
;;
;; The module keeps effects at the edges.  Command builders
;; (`nix-flake--command', `nix-flake--installable') are pure functions
;; that map their arguments to a full argv list; they are the seam the
;; ERT suite drives.  Build-like subcommands (run, build, check, lock,
;; update) stream through `compilation-start'; metadata queries (flake
;; show, flake metadata, registry list) go through `nix--call-json' and
;; `nix--call-lines' because their output must be parsed, not displayed.
;;
;; Flake state is buffer-local and per-project: the target reference and
;; the four option toggles live in the invoking buffer, and the popup
;; reads them on each refresh.

;;; Code:

(require 'nix-core)
(require 'keymap-popup)

(defcustom nix-flake-add-to-registry t
  "When non-nil, add newly entered flake references to the registry.
A reference read by `nix-flake-set-ref' that is not already
registered in the user or global registry is added under a name
read from the minibuffer."
  :type 'boolean
  :group 'nix)

;;; Buffer-local state

;; `nix-flake--ref' is nil until the user sets it explicitly; a nil ref
;; means "the flake in `default-directory'", resolved by
;; `nix-flake--current-ref'.  The four option toggles below are declared
;; by `keymap-popup-define' as buffer-local switches, so they are only
;; forward-declared here for the byte-compiler and the builders.  All
;; four default to nil: print-build-logs is opt-in, a deliberate change
;; from the old transient which defaulted it on.

(defvar-local nix-flake--ref nil
  "Explicit flake reference for this buffer, or nil.
When nil, `nix-flake--current-ref' derives a reference from the
flake in `default-directory'.")

(defvar nix-flake--impure)
(defvar nix-flake--no-update-lock-file)
(defvar nix-flake--commit-lock-file)
(defvar nix-flake--print-build-logs)

;;; Reference resolution

(defun nix-flake--dir-ref (dir)
  "Return the flake reference for local directory DIR.
DIR is located by walking up from `default-directory' to the
directory that contains flake.nix; the reference is that directory
as a \"path:\" URL, which \"nix flake\" accepts anywhere a flake
reference is expected."
  (concat "path:" (directory-file-name (expand-file-name dir))))

(defun nix-flake--current-ref ()
  "Return the flake reference to operate on.
The explicit `nix-flake--ref' wins; otherwise the flake root is
located by `locate-dominating-file' on flake.nix and returned as a
\"path:\" reference, falling back to `default-directory'."
  (or nix-flake--ref
      (nix-flake--dir-ref
       (or (locate-dominating-file default-directory "flake.nix")
           default-directory))))

;;; Options

(defun nix-flake--options ()
  "Return the \"nix\" flag strings for the enabled options.
Each buffer-local switch variable that is non-nil contributes its
command-line flag."
  (append (and nix-flake--impure '("--impure"))
          (and nix-flake--no-update-lock-file '("--no-update-lock-file"))
          (and nix-flake--commit-lock-file '("--commit-lock-file"))
          (and nix-flake--print-build-logs '("--print-build-logs"))))

;;; Command builders (pure)

(defun nix-flake--command (subcommand &rest extra)
  "Return the argv list for flake SUBCOMMAND on the current flake.
SUBCOMMAND is a string like \"check\".  EXTRA arguments follow the
flake reference.  The active option flags are appended last."
  (append (list nix-executable "flake" subcommand (nix-flake--current-ref))
          extra
          (nix-flake--options)))

(defun nix-flake--installable (subcommand &optional attribute)
  "Return the argv list for SUBCOMMAND on an installable of the flake.
SUBCOMMAND is a string like \"build\" or \"run\".  ATTRIBUTE, when
non-nil, is appended to the reference after \"#\"; otherwise the
bare reference selects the default output.  Option flags follow."
  (let ((ref (nix-flake--current-ref)))
    (append (list nix-executable subcommand
                  (if attribute (concat ref "#" attribute) ref))
            (nix-flake--options))))

(defun nix-flake--update-command (&optional inputs)
  "Return the argv list for \"nix flake update\".
INPUTS is a list of input names to update; when nil the whole lock
file is updated.  Nix 2.19+ takes the input names positionally."
  (append (list nix-executable "flake" "update" "--flake"
                (nix-flake--current-ref))
          inputs
          (nix-flake--options)))

(defun nix-flake--init-command (template)
  "Return the argv list for \"nix flake init\" with TEMPLATE.
TEMPLATE is a flake reference with a template attribute, passed to
the \"-t\" flag."
  (list nix-executable "flake" "init" "-t" template))

;;; Attribute discovery (pure over `nix flake show --json')

(defun nix-flake--system-attrs (outputs types)
  "Return attribute names of TYPES for the current system in OUTPUTS.
OUTPUTS is the alist decoded from \"nix flake show --json\".  TYPES
is a list of output kinds such as (packages apps).  Each output of
a listed type is indexed by system tuple; the names under the
current `nix-system' are collected."
  (let ((system (intern (nix-system))))
    (delete-dups
     (mapcan (lambda (type)
               (mapcar (lambda (cell) (symbol-name (car cell)))
                       (alist-get system (alist-get type outputs))))
             types))))

(defun nix-flake--run-attrs (outputs)
  "Return the runnable attribute names in OUTPUTS.
Both apps and packages are runnable via \"nix run\"."
  (nix-flake--system-attrs outputs '(apps packages)))

(defun nix-flake--build-attrs (outputs)
  "Return the buildable attribute names in OUTPUTS.
Only packages are buildable via \"nix build\"."
  (nix-flake--system-attrs outputs '(packages)))

(defun nix-flake--outputs ()
  "Return the parsed \"nix flake show --json\" outputs for the flake."
  (nix--call-json nix-executable
                  (list "flake" "show" "--json" (nix-flake--current-ref))
                  "nix flake show"))

;;; Metadata (pure over `nix flake metadata --json')

(defun nix-flake--metadata-inputs (metadata)
  "Return the root input names from METADATA.
METADATA is the alist decoded from \"nix flake metadata --json\".
The names are read from locks.nodes.root.inputs."
  (mapcar (lambda (cell) (symbol-name (car cell)))
          (let-alist metadata .locks.nodes.root.inputs)))

(defun nix-flake--input-names ()
  "Return the flake's input names via \"nix flake metadata --json\"."
  (nix-flake--metadata-inputs
   (nix--call-json nix-executable
                   (list "flake" "metadata" "--json" (nix-flake--current-ref))
                   "nix flake metadata")))

;;; Registry (pure parsing over `nix registry list')

(defun nix-flake--parse-registry (lines)
  "Parse \"nix registry list\" LINES into (TYPE FROM TO) triples.
Each line is whitespace-separated; malformed lines are dropped."
  (seq-keep (lambda (line)
              (pcase (split-string line "[[:space:]]+" t)
                (`(,type ,from ,to) (list type from to))
                (_ nil)))
            lines))

(defun nix-flake--registry-refs (entries)
  "Return the user and global reference URLs from ENTRIES.
ENTRIES is a list of (TYPE FROM TO) triples as produced by
`nix-flake--parse-registry'.  System entries are dropped because
their targets are opaque store paths."
  (delete-dups
   (mapcan (pcase-lambda (`(,type ,from ,to))
             (and (member type '("user" "global"))
                  (list from to)))
           entries)))

(defun nix-flake--registry-list ()
  "Return the parsed registry entries via \"nix registry list\"."
  (nix-flake--parse-registry
   (nix--call-lines nix-executable '("registry" "list") "nix registry list")))

;;; Executors

(defun nix-flake--shell-command (argv)
  "Return ARGV as a single shell command string, each token quoted."
  (mapconcat #'shell-quote-argument argv " "))

(defun nix-flake--compile (argv name)
  "Run ARGV in a compilation buffer named NAME.
ARGV is a full argv list; it is quoted into a shell command so the
compilation buffer shows a copy-pastable invocation."
  (compilation-start (nix-flake--shell-command argv)
                     nil (lambda (_mode) name)))

;;; Interactive commands

;;;###autoload
(defun nix-flake-run ()
  "Run an app or package attribute of the current flake."
  (interactive)
  (let ((attr (completing-read "Run attribute: "
                               (nix-flake--run-attrs (nix-flake--outputs))
                               nil t)))
    (nix-flake--compile (nix-flake--installable "run" attr) "*nix flake run*")))

;;;###autoload
(defun nix-flake-run-default ()
  "Run the default app or package of the current flake."
  (interactive)
  (nix-flake--compile (nix-flake--installable "run") "*nix flake run*"))

;;;###autoload
(defun nix-flake-build ()
  "Build a package attribute of the current flake."
  (interactive)
  (let ((attr (completing-read "Build attribute: "
                               (nix-flake--build-attrs (nix-flake--outputs))
                               nil t)))
    (nix-flake--compile (nix-flake--installable "build" attr) "*nix flake build*")))

;;;###autoload
(defun nix-flake-build-default ()
  "Build the default package of the current flake."
  (interactive)
  (nix-flake--compile (nix-flake--installable "build") "*nix flake build*"))

;;;###autoload
(defun nix-flake-check ()
  "Run \"nix flake check\" on the current flake."
  (interactive)
  (nix-flake--compile (nix-flake--command "check") "*nix flake check*"))

;;;###autoload
(defun nix-flake-lock ()
  "Create missing lock file entries for the current flake."
  (interactive)
  (nix-flake--compile (nix-flake--command "lock") "*nix flake lock*"))

;;;###autoload
(defun nix-flake-update ()
  "Update the flake lock file.
Prompts for the input names to update; updating none rewrites the
whole lock file."
  (interactive)
  (let ((inputs (completing-read-multiple
                 "Inputs to update (empty for all): "
                 (nix-flake--input-names))))
    (nix-flake--compile (nix-flake--update-command inputs)
                        "*nix flake update*")))

(defun nix-flake--template-names (source)
  "Return the template attribute names in flake SOURCE."
  (mapcar (lambda (cell) (symbol-name (car cell)))
          (alist-get 'templates
                     (nix--call-json nix-executable
                                     (list "flake" "show" "--json" source)
                                     "nix flake show"))))

;;;###autoload
(defun nix-flake-init ()
  "Scaffold a flake from a template.
Reads a source flake from the registry, then a template attribute
from that flake, and runs \"nix flake init -t SOURCE#TEMPLATE\"."
  (interactive)
  (let* ((source (nix-flake--read-ref "Template source flake: "))
         (template (completing-read
                    (format-message "Template from %s: " source)
                    (nix-flake--template-names source) nil t))
         (ref (concat source "#" template)))
    (nix-flake--compile (nix-flake--init-command ref) "*nix flake init*")))

(defun nix-flake--read-ref (&optional prompt)
  "Read a flake reference with completion over registered flakes.
PROMPT defaults to \"Flake reference: \".  When
`nix-flake-add-to-registry' is non-nil and the entered reference is
new, it is added to the registry under a read name."
  (let* ((refs (nix-flake--registry-refs (nix-flake--registry-list)))
         (ref (string-trim
               (completing-read (or prompt "Flake reference: ") refs))))
    (when (and nix-flake-add-to-registry
               (not (string-empty-p ref))
               (not (member ref refs)))
      (nix-flake--registry-add ref))
    ref))

;;;###autoload
(defun nix-flake-set-ref ()
  "Set the buffer-local flake reference for subsequent commands."
  (interactive)
  (setq nix-flake--ref (nix-flake--read-ref))
  (message "Flake: %s" nix-flake--ref))

;;; Registry commands

(defun nix-flake--registry-add (ref &optional name)
  "Add flake REF to the registry under NAME.
NAME defaults to a value read from the minibuffer."
  (let ((name (or name
                  (read-string (format-message "Registry name for %s: " ref)))))
    (unless (string-empty-p name)
      (nix--check (nix--call nix-executable (list "registry" "add" name ref))
                  "nix registry add"))))

;;;###autoload
(defun nix-flake-registry-add ()
  "Add a flake reference to the registry under a name."
  (interactive)
  (let ((name (read-string "Registry name: "))
        (ref (read-string "Flake reference: ")))
    (nix-flake--registry-add ref name)
    (message "Added %s -> %s" name ref)))

;;;###autoload
(defun nix-flake-registry-remove ()
  "Remove a flake reference from the registry by name."
  (interactive)
  (let ((name (completing-read
               "Remove registry entry: "
               (mapcar #'cadr (nix-flake--registry-list)) nil t)))
    (nix--check (nix--call nix-executable (list "registry" "remove" name))
                "nix registry remove")
    (message "Removed %s" name)))

;;;###autoload
(defun nix-flake-registry-list ()
  "Display the flake registry in a help buffer."
  (interactive)
  (let ((entries (nix-flake--registry-list)))
    (with-help-window "*Nix Registry*"
      (with-current-buffer standard-output
        (pcase-dolist (`(,type ,from ,to) entries)
          (insert (format "%-8s %-24s %s\n" type from to)))))))

;;; Popup menus

;; Forward-declared for byte-compilers running against keymap-popup
;; builds that emit the launcher `defun' ahead of the `defvar-keymap'.
(defvar nix-flake-registry-map)
(defvar nix-flake-menu-map)

(keymap-popup-define nix-flake-registry-map
  "Flake registry."
  "a" ("Add" nix-flake-registry-add)
  "r" ("Remove" nix-flake-registry-remove)
  "l" ("List" nix-flake-registry-list))

(keymap-popup-define nix-flake-menu-map
  "Nix flake commands."
  :description (lambda () (format "Flake: %s" (nix-flake--current-ref)))
  :group "Options"
  "r" ("Set reference" nix-flake-set-ref :stay-open t)
  "i" ("Impure" :switch nix-flake--impure)
  "n" ("No lock-file update" :switch nix-flake--no-update-lock-file)
  "C" ("Commit lock file" :switch nix-flake--commit-lock-file)
  "L" ("Print build logs" :switch nix-flake--print-build-logs)
  :group "Run and build"
  "x" ("Run attribute" nix-flake-run)
  "X" ("Run default" nix-flake-run-default)
  "b" ("Build attribute" nix-flake-build)
  "B" ("Build default" nix-flake-build-default)
  :group "Lock file"
  "c" ("Check" nix-flake-check)
  "l" ("Lock" nix-flake-lock)
  "u" ("Update" nix-flake-update)
  :group "Setup"
  "t" ("Init from template" nix-flake-init)
  "R" ("Registry" :keymap nix-flake-registry-map))

;;;###autoload
(defun nix-flake ()
  "Open the Nix flake command menu for the current buffer."
  (interactive)
  (keymap-popup nix-flake-menu-map))

(provide 'nix-flake)
;;; nix-flake.el ends here
