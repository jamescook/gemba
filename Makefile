# gemba - release build and install.
#
# Crystal has no rake and shards has no install task, so the install
# story lives here, the way crystal's own repo and ameba do it.
#
#   make                      release build -> bin/release/gemba
#   make install              -> ~/.local/{bin,share/gemba}
#   make && sudo make install PREFIX=/usr/local   system-wide
#   make DESTDIR=/tmp/stage install    staged, for a formula or .deb
#   make uninstall
#
# PREFIX defaults to ~/.local: no sudo, and it is the XDG/systemd user
# convention that most modern Linux distros put on PATH when it exists
# (Debian/Ubuntu's stock ~/.profile does). macOS does NOT - `install`
# prints a hint when the target bin dir is missing from PATH.
#
# /usr/local is the system-wide choice on both: it is in /etc/paths on
# every Mac, and on Apple Silicon it is not Homebrew's prefix
# (/opt/homebrew), so installing there collides with nothing brew owns.

PREFIX  ?= $(HOME)/.local
DESTDIR ?=

BINDIR  := $(DESTDIR)$(PREFIX)/bin
DATADIR := $(DESTDIR)$(PREFIX)/share/gemba

SHARDS  ?= shards
INSTALL ?= install

# --no-debug drops the ~5MB .dwarf sidecar a debug build leaves beside
# the binary; nothing in a release build reads it.
BUILD_FLAGS ?= --release --no-debug

# Its own directory rather than bin/, where a plain dev `shards build`
# leaves a debug build - make would take that for an up-to-date release
# and install it.
RELEASE_DIR := bin/release
RELEASE_BIN := $(RELEASE_DIR)/gemba

# Everything the binary is compiled or linked from, so the release
# binary is a real file target rather than a phony that always
# recompiles: `make && sudo make install` must only copy, not run a
# second release build as root and leave root-owned files in bin/.
# lib/ is absent in a fresh clone until shards installs it, hence the
# 2>/dev/null.
SOURCES := $(shell find src lib -name '*.cr' 2>/dev/null) shard.yml \
           $(wildcard native/*.o vendor/mgba-install/lib/libmgba.a vendor/rcheevos-build/librcheevos.a)

.PHONY: all build install uninstall clean

all: build

build: $(RELEASE_BIN)

$(RELEASE_BIN): $(SOURCES)
	mkdir -p $(RELEASE_DIR)
	SHARDS_BIN_PATH=$(RELEASE_DIR) $(SHARDS) build $(BUILD_FLAGS)

# The three directories Paths.data_root expects to find under
# share/gemba. assets/ is at the repo root while data/ and locales/ sit
# under src/gemba, so they are copied from different places into one
# flat installed layout - see src/gemba/paths.cr.
install: $(RELEASE_BIN)
	$(INSTALL) -d "$(BINDIR)" "$(DATADIR)"
	$(INSTALL) -m 0755 $(RELEASE_BIN) "$(BINDIR)/gemba"
#	Removed first so a re-install replaces rather than nests
#	(cp -R into an existing dir would create share/gemba/assets/assets).
	rm -rf "$(DATADIR)/assets" "$(DATADIR)/data" "$(DATADIR)/locales"
	cp -R assets "$(DATADIR)/assets"
	cp -R src/gemba/data "$(DATADIR)/data"
	cp -R src/gemba/locales "$(DATADIR)/locales"
#	cp preserves the umask, which can leave a system-wide install
#	unreadable to anyone but the installing user.
	find "$(DATADIR)" -type d -exec chmod 0755 {} +
	find "$(DATADIR)" -type f -exec chmod 0644 {} +
	@echo "Installed $(BINDIR)/gemba"
	@echo "          $(DATADIR)"
#	A staged install (DESTDIR set) is not meant to be run from where
#	it lands, so the PATH hint would be noise.
	@if [ -z "$(DESTDIR)" ]; then \
	  case ":$$PATH:" in \
	    *":$(PREFIX)/bin:"*) ;; \
	    *) echo ""; \
	       echo "Note: $(PREFIX)/bin is not on your PATH. Add it with:"; \
	       echo "  echo 'export PATH=\"$(PREFIX)/bin:\$$PATH\"' >> ~/.zshrc" ;; \
	  esac; \
	fi

uninstall:
	rm -f "$(BINDIR)/gemba"
	rm -rf "$(DATADIR)"
	@echo "Removed $(BINDIR)/gemba and $(DATADIR)"

clean:
	rm -rf bin
