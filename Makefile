EMACS_INCLUDE ?= /Applications/MacPorts/Emacs.app/Contents/Resources/include

navigation-modifiers.so: navigation-modifiers.c
	xcrun clang -Wall -Wextra -Werror -O2 -bundle -I"$(EMACS_INCLUDE)" \
		-framework CoreGraphics -o $@ $<
