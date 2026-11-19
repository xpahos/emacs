EMACS_INCLUDE ?= /Applications/MacPorts/Emacs.app/Contents/Resources/include

navigation-modifiers.so: navigation-modifiers.c
	xcrun clang -Wall -Wextra -Werror -O2 -bundle -I"$(EMACS_INCLUDE)" \
		-framework CoreGraphics -o $@ $<

.PHONY: pi-acp
pi-acp:
	npm ci --prefix tools/pi-acp --ignore-scripts --no-audit --no-fund

EMACS ?= /Applications/MacPorts/Emacs.app/Contents/MacOS/Emacs
.PHONY: test-keyboard
test-keyboard:
	$(EMACS) -Q --batch -l tests/keyboard-tests.el -f ert-run-tests-batch-and-exit

.PHONY: test-terminal test-terminal-gui
test-terminal:
	python3 tests/shell-history-tests.py
	$(EMACS) -Q --batch -l tests/terminal-tests.el --eval '(ert-run-tests-batch-and-exit "my-shell-")'

test-terminal-gui:
	test_home=$$(mktemp -d -t emacs-terminal-gui) && \
	EMACS_TEST_HOME=$$test_home $(EMACS) -Q -l $(CURDIR)/tests/gui-terminal-smoke.el; \
	status=$$?; cat $$test_home/result 2>/dev/null; exit $$status

.PHONY: test-pi-history test-pi-history-gui
test-pi-history:
	$(EMACS) -Q --batch -l tests/pi-history-tests.el -f ert-run-tests-batch-and-exit

test-pi-history-gui:
	EMACS="$(EMACS)" python3 tests/run-pi-history-gui.py

.PHONY: test-markdown
test-markdown:
	$(EMACS) -Q --batch -l tests/markdown-view-tests.el -f ert-run-tests-batch-and-exit

.PHONY: test-line-blame test-line-blame-gui
test-line-blame:
	$(EMACS) -Q --batch -l tests/line-blame-tests.el -f ert-run-tests-batch-and-exit

test-line-blame-gui:
	home=$$(mktemp -d -t emacs-line-blame-gui) && \
	EMACS_TEST_HOME=$$home $(EMACS) -Q -l $(CURDIR)/tests/gui-line-blame-smoke.el; \
	status=$$?; cat $$home/result 2>/dev/null; exit $$status

.PHONY: test-worktrees test-worktrees-gui
test-worktrees:
	$(EMACS) -Q --batch -l tests/worktrees-tests.el -f ert-run-tests-batch-and-exit
	$(EMACS) -Q --batch -l tests/worktree-agent-tests.el -f ert-run-tests-batch-and-exit

# Opt-in: verifies rejection of missing branches against a real Arc mount (read-only).
.PHONY: test-worktrees-arc
test-worktrees-arc:
	EMACS_TEST_REAL_ARC=1 $(EMACS) -Q --batch -l tests/worktrees-arc-tests.el \
	  --eval '(ert-run-tests-batch-and-exit "real-arc")'

# Two GUI processes share one temporary home: save, then restart and restore.
test-worktrees-gui:
	home=$$(mktemp -d -t emacs-worktree-gui) && \
	for phase in save restore; do \
	  EMACS_TEST_HOME=$$home EMACS_TEST_PHASE=$$phase $(EMACS) -Q -l $(CURDIR)/tests/gui-worktree-smoke.el \
	    || { cat $$home/failure.txt; echo; exit 1; }; \
	done; cat $$home/*.passed

# Explicit opt-in: existing remote only; creates/removes a disposable local mount, never pushes.
.PHONY: test-worktrees-arc-lifecycle
test-worktrees-arc-lifecycle:
	@test -n "$(EMACS_TEST_ARC_SOURCE)" -a -n "$(EMACS_TEST_ARC_REMOTE)"
	EMACS_TEST_REAL_ARC=1 EMACS_TEST_ARC_LIFECYCLE=1 $(EMACS) -Q --batch -l tests/worktrees-arc-tests.el \
	  --eval '(ert-run-tests-batch-and-exit "real-arc")'

.PHONY: test-agent-completion test-agent-completion-gui
test-agent-completion:
	$(EMACS) -Q --batch -l tests/agent-completion-tests.el -f ert-run-tests-batch-and-exit

test-agent-completion-gui:
	home=$$(mktemp -d -t emacs-agent-completion) && \
	EMACS_TEST_HOME=$$home $(EMACS) -Q -l $(CURDIR)/tests/gui-agent-completion-smoke.el; \
	status=$$?; cat $$home/passed $$home/failure 2>/dev/null; exit $$status
