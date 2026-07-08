;;; nix-test-repl.el --- Tests for nix-repl  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Thanos Apollo

;;; Commentary:

;; Tests for `nix-repl'.  The pure seam `nix-repl--parse-candidates' is
;; exercised against fixture strings captured verbatim from a real
;; "nix repl" session (Nix 2.34) so the parser stays honest without a
;; live process.  `nix-repl--attr-bounds' and the history-path helper are
;; likewise pure.  A binary-gated smoke test proves the comint front-end
;; actually evaluates, and is skipped when Nix or its integration is
;; unavailable.

;;; Code:

(require 'ert)
(require 'nix-repl)

;;; Group 1: candidate parser fixtures
;;
;; Captured verbatim by sending "PREFIX\t\t" to "nix repl" (Nix 2.34.7)
;; and recording the raw process echo.  \r appears in the multi-column
;; listings; the trailing "nix-repl> ..." fragments are readline
;; redisplaying the edited line and must be discarded.

(defconst nix-repl-test--fixture-multi
  "builtins.fetchT\nbuiltins.fetchTarball  builtins.fetchTree\nnix-repl> builtins.fetchT\nbuiltins.fetchTarball  builtins.fetchTree\nnix-repl> builtins.fetchT nix-repl> builtins.fetch nix-repl> builtins.f nix-repl> builtins. nix-repl> b nix-repl> "
  "Two-candidate readline listing for prefix \"builtins.fetchT\".")

(defconst nix-repl-test--fixture-many
  "builtins.f\nbuiltins.false             builtins.findFile\nbuiltins.fetchGit          builtins.flakeRefToString\nbuiltins.fetchMercurial    builtins.floor\nbuiltins.fetchTarball      builtins.foldl'\nbuiltins.fetchTree         builtins.fromJSON\nbuiltins.fetchurl          builtins.fromTOML\nbuiltins.filter            builtins.functionArgs\nbuiltins.filterSource\nnix-repl> builtins.f nix-repl> builtins. nix-repl> b nix-repl> "
  "Multi-column readline listing for prefix \"builtins.f\".")

(defconst nix-repl-test--fixture-single
  "builtins\nbuiltins\nnix-repl> builtins"
  "Unique readline completion extending \"buil\" to \"builtins\".")

(defconst nix-repl-test--fixture-none
  "builtins.abc123zzz"
  "Empty readline completion for a prefix with no matches.")

(defconst nix-repl-test--fixture-noop
  "map\nmap\nnix-repl> map\nmap\nnix-repl> map"
  "Readline listing where the prefix is already complete.")

(ert-deftest nix-repl-test-parse-empty-output-returns-nil ()
  (should-not (nix-repl--parse-candidates "builtins.f" "")))

(ert-deftest nix-repl-test-parse-multi-candidate ()
  "A two-column listing yields both full attribute paths."
  (should (equal '("builtins.fetchTarball" "builtins.fetchTree")
                 (nix-repl--parse-candidates
                  "builtins.fetchT" nix-repl-test--fixture-multi))))

(ert-deftest nix-repl-test-parse-many-candidates ()
  "Every column of a wide listing becomes a candidate; none are dropped."
  (let ((cands (nix-repl--parse-candidates
                "builtins.f" nix-repl-test--fixture-many)))
    (should (= 15 (length cands)))
    (should (member "builtins.fetchTarball" cands))
    (should (member "builtins.functionArgs" cands))
    (should (member "builtins.foldl'" cands))
    (should (seq-every-p (lambda (c) (string-prefix-p "builtins.f" c)) cands))))

(ert-deftest nix-repl-test-parse-single-completion ()
  "A unique extension returns the completed word, not the prefix."
  (should (equal '("builtins")
                 (nix-repl--parse-candidates
                  "buil" nix-repl-test--fixture-single))))

(ert-deftest nix-repl-test-parse-no-completion ()
  "A prefix with no matches yields nil."
  (should-not (nix-repl--parse-candidates
               "builtins.abc123zzz" nix-repl-test--fixture-none)))

(ert-deftest nix-repl-test-parse-already-complete ()
  "When only the prefix echoes back there is nothing to offer."
  (should-not (nix-repl--parse-candidates
               "map" nix-repl-test--fixture-noop)))

(ert-deftest nix-repl-test-parse-strips-prompt-junk ()
  "No candidate is ever a bare \"nix-repl>\" prompt fragment."
  (let ((cands (nix-repl--parse-candidates
                "builtins.f" nix-repl-test--fixture-many)))
    (should-not (member "nix-repl>" cands))
    (should-not (seq-find (lambda (c) (string-match-p "nix-repl" c)) cands))))

;;; Group 2: attribute-path bounds

(defmacro nix-repl-test--with-point (content &rest body)
  "Insert CONTENT in a temp buffer, place point at \"|\", run BODY.
The literal \"|\" in CONTENT marks the cursor and is removed."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (insert ,content)
     (goto-char (point-min))
     (search-forward "|")
     (delete-char -1)
     ,@body))

(ert-deftest nix-repl-test-attr-bounds-covers-dotted-path ()
  "Bounds span the whole dotted attribute path around point."
  (nix-repl-test--with-point "builtins.fetchT|"
			     (let ((bounds (nix-repl--attr-bounds)))
			       (should bounds)
			       (should (equal "builtins.fetchT"
					      (buffer-substring (car bounds) (cdr bounds)))))))

(ert-deftest nix-repl-test-attr-bounds-midway ()
  "Point in the middle of a path still yields the full path."
  (nix-repl-test--with-point "buil|tins.foo"
			     (let ((bounds (nix-repl--attr-bounds)))
			       (should (equal "builtins.foo"
					      (buffer-substring (car bounds) (cdr bounds)))))))

(ert-deftest nix-repl-test-attr-bounds-nil-on-whitespace ()
  "No path at point returns nil."
  (nix-repl-test--with-point "a + | b"
			     (should-not (nix-repl--attr-bounds))))

;;; Group 3: history path

(ert-deftest nix-repl-test-history-honours-xdg ()
  "The history path lives under $XDG_DATA_HOME when set."
  (let ((process-environment
         (cons "XDG_DATA_HOME=/tmp/xdg" process-environment)))
    (should (equal "/tmp/xdg/nix/repl-history" (nix-repl--history-file)))))

(ert-deftest nix-repl-test-history-defaults-when-xdg-empty ()
  "An empty $XDG_DATA_HOME falls back to ~/.local/share."
  (let ((process-environment (cons "XDG_DATA_HOME=" process-environment)))
    (should (equal (expand-file-name "~/.local/share/nix/repl-history")
                   (nix-repl--history-file)))))

;;; Group 4: integration smoke test (binary-gated)

(ert-deftest nix-repl-test-integration-evaluates ()
  "Starting the REPL and sending \"1 + 1\" yields \"2\" in the buffer."
  :tags '(:integration)
  (skip-unless (and (executable-find "nix")
                    (not (getenv "NIX_MODE_SKIP_INTEGRATION"))))
  (let ((buffer (nix-repl--ensure-buffer)))
    (unwind-protect
        (with-current-buffer buffer
          (let ((process (get-buffer-process buffer)))
            (nix-repl-test--wait-for process nix-repl-prompt-regexp 10)
            (goto-char (point-max))
            (insert "1 + 1")
            (comint-send-input)
            (nix-repl-test--wait-for process "^2$" 10)
            (should (save-excursion
                      (goto-char (point-min))
                      (re-search-forward "^2$" nil t)))))
      (let ((process (get-buffer-process buffer)))
        (when (process-live-p process) (delete-process process)))
      (kill-buffer buffer))))

(defun nix-repl-test--wait-for (process regexp seconds)
  "Poll PROCESS output until REGEXP appears or SECONDS elapse.
Uses bounded `accept-process-output' so batch runs never block."
  (let ((deadline (+ (float-time) seconds)))
    (while (and (< (float-time) deadline)
                (not (save-excursion
                       (goto-char (point-min))
                       (re-search-forward regexp nil t))))
      (accept-process-output process 0.2))))

(provide 'nix-test-repl)
;;; nix-test-repl.el ends here
