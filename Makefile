# All Ears — build, install, and uninstall.
#
# `make install` builds the release binaries, signs them, puts the five tools
# on your PATH, and runs `earsd` as a per-user launchd LaunchAgent (started at
# login, kept alive, PATH wired so the meeting on_end `transcribe` hook works).
# `make uninstall` stops and removes the agent and the binaries, leaving your
# recordings, config, and transcripts untouched.
#
# Common overrides:
#   make install PREFIX=/usr/local            # install under /usr/local/bin
#   make install SIGN_IDENTITY="Developer ID Application: You (TEAMID)"
#
# Keep this a plain Makefile with no external tooling — just swift, codesign,
# and launchctl, all part of a standard Xcode/CLT + macOS install.

# --- Configuration --------------------------------------------------------

# Where the binaries go. Default to ~/.local/bin so `make install` needs no
# sudo and runs entirely as the logged-in user (the LaunchAgent must be
# bootstrapped into *your* GUI session, not root's). Override with
# PREFIX=/usr/local for a system-wide install — see the note in `install`.
PREFIX ?= $(HOME)/.local
BINDIR := $(PREFIX)/bin

DAEMON  := daemon
RELEASE := $(DAEMON)/.build/release
BINS    := earsd ears transcribe cleanup summarize

LABEL         := net.tomelliot.ears.earsd
LAUNCH_AGENTS := $(HOME)/Library/LaunchAgents
PLIST_SRC     := packaging/$(LABEL).plist.in
PLIST_DEST    := $(LAUNCH_AGENTS)/$(LABEL).plist
ENTITLEMENTS  := packaging/earsd.entitlements
LOGDIR        := $(HOME)/Library/Logs/ears

# Stable code-signing identity. Leave empty to auto-detect a "Developer ID
# Application" identity, falling back to ad-hoc (`--sign -`) with a warning.
SIGN_IDENTITY ?=

# Installs are a strict ordered sequence; never parallelize them.
.NOTPARALLEL:

.PHONY: help build sign install install-bin install-agent \
        uninstall uninstall-bin uninstall-agent reinstall status guard-user

# --- Top-level targets ----------------------------------------------------

help:
	@echo "All Ears — Makefile targets:"
	@echo "  make build        Build release binaries (swift build -c release)"
	@echo "  make sign         Code-sign the built binaries (needs build first)"
	@echo "  make install      Build, sign, install to \$$PREFIX/bin, load the LaunchAgent"
	@echo "  make uninstall    Stop/remove the LaunchAgent and the installed binaries"
	@echo "  make reinstall    Reinstall over an existing install (upgrade in place)"
	@echo "  make status       Show the LaunchAgent state and \`ears status\`"
	@echo ""
	@echo "Variables:"
	@echo "  PREFIX=$(PREFIX)"
	@echo "  SIGN_IDENTITY=\"$(SIGN_IDENTITY)\"  (empty = auto-detect Developer ID, else ad-hoc)"

build:
	@echo "==> Building release binaries (swift build -c release)"
	cd $(DAEMON) && swift build -c release

# Sign the built binaries in place, before they are copied to $(BINDIR).
# codesign embeds the signature in the Mach-O, so a later `install`/copy keeps
# it. earsd gets Hardened Runtime + the audio-input entitlement so it can reach
# the microphone/system audio once signed; the CLIs are signed for a stable
# identity but need no entitlements.
sign: build
	@echo "==> Signing binaries"
	@IDENTITY="$(SIGN_IDENTITY)"; \
	if [ -z "$$IDENTITY" ]; then \
	  IDENTITY="$$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Developer ID Application/ {print $$2; exit}')"; \
	fi; \
	if [ -z "$$IDENTITY" ]; then \
	  echo "  WARNING: no 'Developer ID Application' signing identity found."; \
	  echo "           Falling back to ad-hoc signing (--sign -)."; \
	  echo "           macOS ties the microphone / system-audio grant to the code-"; \
	  echo "           signing identity. An ad-hoc signature's hash changes every"; \
	  echo "           rebuild, so macOS may re-prompt (or silently drop the grant)"; \
	  echo "           after a reinstall. For a grant that survives upgrades, pass"; \
	  echo "           SIGN_IDENTITY=\"Developer ID Application: You (TEAMID)\"."; \
	  IDENTITY="-"; \
	else \
	  echo "  signing identity: $$IDENTITY"; \
	fi; \
	echo "  codesign earsd (Hardened Runtime + audio-input entitlement)"; \
	codesign --force --options runtime --entitlements "$(ENTITLEMENTS)" --sign "$$IDENTITY" "$(RELEASE)/earsd"; \
	for b in ears transcribe cleanup summarize; do \
	  echo "  codesign $$b"; \
	  codesign --force --options runtime --sign "$$IDENTITY" "$(RELEASE)/$$b"; \
	done

install: guard-user build sign install-bin install-agent
	@echo ""
	@echo "==> Installed. earsd is running as a LaunchAgent ($(LABEL))."
	@echo "    Binaries:    $(BINDIR)"
	@echo "    LaunchAgent: $(PLIST_DEST)"
	@echo "    Logs:        $(LOGDIR)"
	@case ":$$PATH:" in \
	  *":$(BINDIR):"*) ;; \
	  *) echo ""; \
	     echo "    NOTE: $(BINDIR) is not on your PATH. Add it, e.g.:"; \
	     echo "          echo 'export PATH=\"$(BINDIR):\$$PATH\"' >> ~/.zshrc && exec \$$SHELL";; \
	esac
	@echo ""
	@echo "    Try:  ears status"

reinstall: install

uninstall: guard-user uninstall-agent uninstall-bin
	@echo ""
	@echo "==> Uninstalled the LaunchAgent and binaries."
	@echo "    Your data was left in place:"
	@echo "      config:      ~/.config/ears/config.toml"
	@echo "      data:        ~/Library/Application Support/ears"
	@echo "      transcripts: ~/Documents/Transcripts"
	@echo "      logs:        $(LOGDIR)"

status:
	@echo "==> LaunchAgent $(LABEL)"
	@launchctl print gui/$$(id -u)/$(LABEL) 2>/dev/null | grep -E '^\s*(state|pid|program) ' || \
	  echo "  not loaded"
	@echo "==> ears status"
	@"$(BINDIR)/ears" status 2>/dev/null || ears status 2>/dev/null || echo "  (ears not on PATH)"

# --- Building blocks ------------------------------------------------------

# Refuse to run the user-scoped steps under sudo: $(HOME) and gui/$(id -u)
# would resolve to root, bootstrapping the agent into the wrong session and
# writing the plist to root's LaunchAgents. Binary install auto-elevates on
# its own only for the copy when $(BINDIR) isn't writable (see install-bin).
guard-user:
	@if [ "$$(id -u)" = "0" ] && [ -n "$$SUDO_USER" ]; then \
	  echo "error: run 'make $(MAKECMDGOALS)' as your normal user, not under sudo."; \
	  echo "       The LaunchAgent must load into your GUI session (gui/\$$UID), not root's."; \
	  echo "       For a /usr/local install, the copy elevates itself with sudo as needed."; \
	  exit 1; \
	fi

install-bin: build sign
	@echo "==> Installing binaries to $(BINDIR)"
	@mkdir -p "$(BINDIR)" 2>/dev/null || sudo mkdir -p "$(BINDIR)"
	@if [ -w "$(BINDIR)" ]; then SUDO=""; else SUDO="sudo"; \
	  echo "  $(BINDIR) is not writable; using sudo for the copy."; fi; \
	for b in $(BINS); do \
	  echo "  install $$b -> $(BINDIR)/$$b"; \
	  $$SUDO install -m 0755 "$(RELEASE)/$$b" "$(BINDIR)/$$b"; \
	done

# Render the plist from the template, then reload the agent: bootout first so a
# reinstall picks up the new binary, then bootstrap the fresh plist.
install-agent: guard-user
	@echo "==> Installing LaunchAgent"
	@mkdir -p "$(LAUNCH_AGENTS)" "$(LOGDIR)"
	@echo "  render $(PLIST_DEST)"
	@sed -e 's#@PREFIX@#$(PREFIX)#g' -e 's#@HOME@#$(HOME)#g' "$(PLIST_SRC)" > "$(PLIST_DEST)"
	@echo "  reload agent (bootout + bootstrap gui/$$(id -u))"
	@launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null || true
	@# bootout is asynchronous: bootstrapping while the old instance is still
	@# tearing down fails with "Bootstrap failed: 5: Input/output error".
	@# Wait (up to ~5s) for the label to disappear before bootstrapping.
	@i=0; while launchctl print gui/$$(id -u)/$(LABEL) >/dev/null 2>&1 && [ $$i -lt 20 ]; do sleep 0.25; i=$$((i+1)); done
	@launchctl bootstrap gui/$$(id -u) "$(PLIST_DEST)"
	@launchctl enable gui/$$(id -u)/$(LABEL) 2>/dev/null || true
	@launchctl kickstart -k gui/$$(id -u)/$(LABEL) 2>/dev/null || true

uninstall-agent: guard-user
	@echo "==> Removing LaunchAgent"
	@launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null || true
	@rm -f "$(PLIST_DEST)"
	@echo "  removed $(PLIST_DEST)"

uninstall-bin:
	@echo "==> Removing binaries from $(BINDIR)"
	@if [ -w "$(BINDIR)" ]; then SUDO=""; else SUDO="sudo"; fi; \
	for b in $(BINS); do \
	  if [ -e "$(BINDIR)/$$b" ]; then \
	    echo "  rm $(BINDIR)/$$b"; \
	    $$SUDO rm -f "$(BINDIR)/$$b"; \
	  fi; \
	done
