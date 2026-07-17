.PHONY: all build dev autoload compile lint lint-check-declare lint-checkdoc \
        lint-package-lint lint-relint lint-test-compile \
        clean clean-elc check test test-oneshot load \
        do-build do-dev do-lint do-test do-test-oneshot do-test-summary \
        do-lint-check-declare do-lint-checkdoc \
        do-lint-package-lint do-lint-relint do-lint-test-compile

NIX := $(shell command -v nix 2>/dev/null)

ENV_MAKE = $(MAKE) --no-print-directory
ifeq ($(NIX_MODE_ENV_WRAPPED),)
ifneq ($(NIX),)
ENV_MAKE = nix develop path:$(CURDIR) --command env NIX_MODE_ENV_WRAPPED=1 $(MAKE) --no-print-directory
endif
endif

EMACS_CMD ?= emacs
EMACS_OPTS ?= -Q --batch

JOBS         ?= $(shell nproc 2>/dev/null || echo 4)
TEST_RESULTS := .test-results

LISP_FILES := $(filter-out lisp/nix-mode-autoloads.el,$(wildcard lisp/*.el))
TESTS      ?= $(wildcard tests/nix-test-*.el)

TEST_STAMPS := $(patsubst tests/%.el,$(TEST_RESULTS)/%.stamp,$(TESTS))

all: build

build:
	@$(ENV_MAKE) do-build

do-build: autoload compile

dev:
	@$(ENV_MAKE) do-dev

do-dev: autoload compile do-lint do-test

autoload:
	@if [ -n "$(LISP_FILES)" ]; then \
	  $(EMACS_CMD) $(EMACS_OPTS) -L lisp \
	  --eval="(loaddefs-generate \"lisp\" \"lisp/nix-mode-autoloads.el\")"; \
	fi

compile: autoload
	@if [ -n "$(LISP_FILES)" ]; then \
	  $(EMACS_CMD) $(EMACS_OPTS) -L . -L lisp \
	  --eval="(setq print-length nil load-prefer-newer t)" \
	  -f batch-byte-compile $(LISP_FILES); \
	fi

lint-check-declare:
	@$(ENV_MAKE) do-lint-check-declare

do-lint-check-declare:
	@for file in $(LISP_FILES) ; do \
	  $(EMACS_CMD) $(EMACS_OPTS) --eval="(check-declare-file \"$$file\")" ; \
	done

lint-checkdoc:
	@$(ENV_MAKE) do-lint-checkdoc

do-lint-checkdoc:
	@for file in $(LISP_FILES) ; do \
	  $(EMACS_CMD) $(EMACS_OPTS) --eval="(checkdoc-file \"$$file\")" ; \
	done

lint-package-lint:
	@$(ENV_MAKE) do-lint-package-lint

do-lint-package-lint:
	@if [ -n "$(LISP_FILES)" ]; then \
	  $(EMACS_CMD) $(EMACS_OPTS) \
	  --eval='(package-initialize)' \
	  --eval="(unless package-archive-contents (ignore-errors (package-refresh-contents)))" \
	  --eval="(require 'package-lint)" \
	  --eval="(setq package-lint-main-file \"lisp/nix-mode.el\")" \
	  -f 'package-lint-batch-and-exit' $(LISP_FILES); \
	fi

lint-relint:
	@$(ENV_MAKE) do-lint-relint

do-lint-relint:
	@if [ -n "$(LISP_FILES)" ]; then \
	  $(EMACS_CMD) $(EMACS_OPTS) \
	  --eval='(package-initialize)' --eval="(require 'relint)" \
	  -f 'relint-batch' "lisp"; \
	fi

lint-test-compile:
	@$(ENV_MAKE) do-lint-test-compile

do-lint-test-compile:
	@if [ -n "$(TESTS)" ]; then \
	  $(EMACS_CMD) $(EMACS_OPTS) -L lisp -L tests \
	  -f batch-byte-compile $(TESTS); \
	fi

lint:
	@$(ENV_MAKE) do-lint

do-lint: do-lint-check-declare do-lint-checkdoc do-lint-package-lint do-lint-relint do-lint-test-compile

test:
	@$(ENV_MAKE) -j$(JOBS) -Otarget do-test

do-test: autoload
	@rm -rf $(TEST_RESULTS)
	@mkdir -p $(TEST_RESULTS)
	@$(MAKE) --no-print-directory -j$(JOBS) -Otarget do-test-summary

$(TEST_RESULTS)/%.stamp: tests/%.el
	@output=$$($(EMACS_CMD) $(EMACS_OPTS) -L lisp -L tests \
	  -l ert -l $< -f ert-run-tests-batch-and-exit 2>&1); \
	rc=$$?; \
	n=$$(echo "$$output" | grep -o 'Ran [0-9]*' | grep -o '[0-9]*'); \
	if [ $$rc -ne 0 ]; then \
	  printf "\033[31mFAIL\033[0m $< ($${n:-0} tests)\n"; \
	  echo "$$output" | grep '  FAILED'; \
	  printf "FAIL %s\n" "$${n:-1}" > $@; \
	else \
	  printf "\033[32m  OK\033[0m $< ($$n tests)\n"; \
	  printf "OK %s\n" "$$n" > $@; \
	fi

test-oneshot:
	@$(ENV_MAKE) do-test-oneshot

# Load every test file into one Emacs process and run the whole suite
# twice.  Surfaces cross-test state pollution and in-place mutation of
# shared literals that the per-file `do-test' runs cannot see.
do-test-oneshot: autoload
	@if [ -n "$(TESTS)" ]; then \
	  $(EMACS_CMD) $(EMACS_OPTS) -L lisp -L tests -l ert \
	    $(addprefix -l ,$(TESTS)) \
	    --eval="(let ((bad 0)) \
	              (dotimes (_ 2) \
	                (setq bad (+ bad (ert-stats-completed-unexpected \
	                                  (ert-run-tests-batch t))))) \
	              (kill-emacs (if (zerop bad) 0 1)))"; \
	else \
	  echo "No test files yet."; \
	fi

do-test-summary: $(TEST_STAMPS)
	@total=0; passed=0; failed=0; failed_files=""; \
	for f in $(TEST_STAMPS); do \
	  [ -f "$$f" ] || continue; \
	  read status n < $$f; \
	  total=$$((total + n)); \
	  if [ "$$status" = "FAIL" ]; then \
	    failed=$$((failed + n)); \
	    base=$$(basename $$f .stamp); \
	    failed_files="$$failed_files tests/$$base.el"; \
	  else \
	    passed=$$((passed + n)); \
	  fi; \
	done; \
	echo ""; \
	if [ $$failed -eq 0 ]; then \
	  printf "\033[32m$$total tests, $$passed passed, 0 failed\033[0m\n"; \
	  rm -rf $(TEST_RESULTS); \
	else \
	  printf "\033[31m$$total tests, $$passed passed, $$failed failed\033[0m\n"; \
	  for f in $$failed_files; do echo "  $$f"; done; \
	  printf "\nStamps preserved in $(TEST_RESULTS)/ for debugging.\n"; \
	fi; \
	[ $$failed -eq 0 ]

load: clean-elc
	@emacsclient --eval "(progn \
	  (add-to-list 'load-path \"$(CURDIR)/lisp\") \
	  (dolist (sym '(nix-mode-map nix-repl-mode-map \
	                 nix-store-path-mode-map nix-search-mode-map \
	                 nix-flake-menu-map nix-flake-registry-map \
	                 nix-menu-map)) \
	    (when (boundp sym) (makunbound sym))))" > /dev/null
	@emacsclient --eval "(load-file \"$(CURDIR)/lisp/nix-core.el\")" > /dev/null || \
	    { printf "\033[31mFAIL\033[0m lisp/nix-core.el\n"; exit 1; }
	@for f in $(LISP_FILES); do \
	  emacsclient --eval "(load-file \"$(CURDIR)/$$f\")" > /dev/null || \
	    { printf "\033[31mFAIL\033[0m $$f\n"; exit 1; }; \
	done
	@printf "\033[32mLoaded all lisp/*.el into Emacs\033[0m\n"

clean-elc:
	find . -name '*.elc' -delete
	find . -name '.#*' -delete
	find . -name '#*#' -delete

clean: clean-elc
	rm -rf $(TEST_RESULTS)

check: test
