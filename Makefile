EMACS_INCLUDE ?= /Applications/MacPorts/Emacs.app/Contents/Resources/include

navigation-modifiers.so: navigation-modifiers.c
	xcrun clang -Wall -Wextra -Werror -O2 -bundle -I"$(EMACS_INCLUDE)" \
		-framework CoreGraphics -o $@ $<

.PHONY: pi-acp
pi-acp:
	npm ci --prefix tools/pi-acp --ignore-scripts --no-audit --no-fund

EMACS ?= /Applications/MacPorts/Emacs.app/Contents/MacOS/Emacs
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
