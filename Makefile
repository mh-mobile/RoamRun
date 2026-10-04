APP_NAME = RoamRun
BUNDLE = $(APP_NAME).app
BINARY = .build/release/$(APP_NAME)
VERSION = $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
DMG = $(APP_NAME)-$(VERSION).dmg

# Distribution: make dmg SIGN_ID="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=<profile>
# (profile from: xcrun notarytool store-credentials <profile>). Defaults to ad-hoc, no notarization.
SIGN_ID ?= -
NOTARY_PROFILE ?=
SIGN_FLAGS = --force --options runtime $(if $(filter -,$(SIGN_ID)),,--timestamp)

.PHONY: all build app run dmg release-dmg icon install-cli test clean device-lib device-probe

all: app

# xcrun pins Xcode's toolchain; a swiftly `swift` first in PATH breaks the build.
# SNAPSHOT=1 compiles in the MB_SNAPSHOT screenshot mode (dev only; never in a dmg).
build:
	xcrun swift build -c release $(if $(SNAPSHOT),-Xswiftc -DSNAPSHOT)

app: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	# SwiftPM records the deployment target (13.0) as the SDK version, which
	# makes macOS run the app in compatibility mode — no Liquid Glass. Stamp
	# the real SDK version; the minimum OS stays 13.0.
	xcrun vtool -set-build-version macos 13.0 $(shell xcrun --show-sdk-version) -replace \
		-output $(BUNDLE)/Contents/MacOS/$(APP_NAME) $(BINARY)
	cp Info.plist $(BUNDLE)/Contents/Info.plist
	mkdir -p $(BUNDLE)/Contents/Resources
	cp Resources/AppIcon.icns $(BUNDLE)/Contents/Resources/
	cp skills/roamrun/SKILL.md $(BUNDLE)/Contents/Resources/roamrun-skill.md
	codesign -s "$(SIGN_ID)" $(SIGN_FLAGS) $(BUNDLE)
	@echo "Built $(BUNDLE)"

# Pure logic only (parsers, ownership rules); the bridge itself needs a real iPhone.
test:
	xcrun swift test

# Experimental (device control): RoamRun's own Rust library over idevice (pinned in its
# Cargo.toml and Cargo.lock), for macOS. Needs Rust 1.88+; nothing else here depends on it.
# CARGO= picks the cargo to use (e.g. "$$HOME/.cargo/bin/cargo +1.95.0").
CARGO ?= cargo
device-lib:
	# The C objects idevice's crypto brings get the app's deployment target; setting
	# MACOSX_DEPLOYMENT_TARGET instead also reaches the proc-macro dylibs, which then don't load.
	cd Rust/RoamRunDevice && CFLAGS_aarch64_apple_darwin="-mmacosx-version-min=13.0" \
		$(CARGO) build --release --locked --target-dir $(CURDIR)/.build/device

# Links it into a Swift executable. With no arguments it only says what it is; with
# <device ip> <RemotePairing port> <pairing file> it verifies the pairing, opens a tunnel
# and lists the services device control needs. No input is sent to the device.
device-probe: device-lib
	ROAMRUN_DEVICE=1 xcrun swift run -c release DeviceProbe $(ARGS)

run: app
	open $(BUNDLE)

dmg: app
	@if [ -n "$(SNAPSHOT)" ]; then echo "SNAPSHOT builds are for development only"; exit 1; fi
	@if [ -n "$(NOTARY_PROFILE)" ] && [ "$(SIGN_ID)" = "-" ]; then echo "NOTARY_PROFILE needs SIGN_ID (a Developer ID Application identity)"; exit 1; fi
ifneq ($(NOTARY_PROFILE),)
	# The app gets its own ticket too: a Homebrew install never opens the dmg, and
	# a stapled app passes Gatekeeper even offline.
	ditto -c -k --keepParent $(BUNDLE) $(APP_NAME)-notarize.zip
	xcrun notarytool submit $(APP_NAME)-notarize.zip --keychain-profile $(NOTARY_PROFILE) --wait
	rm -f $(APP_NAME)-notarize.zip
	xcrun stapler staple $(BUNDLE)
endif
	rm -rf dmg-root $(DMG)
	mkdir dmg-root
	cp -R $(BUNDLE) dmg-root/
	ln -s /Applications dmg-root/Applications
	hdiutil create -volname $(APP_NAME) -srcfolder dmg-root -ov -format UDZO $(DMG)
	rm -rf dmg-root
ifneq ($(SIGN_ID),-)
	codesign -s "$(SIGN_ID)" --timestamp $(DMG)
endif
ifneq ($(NOTARY_PROFILE),)
	xcrun notarytool submit $(DMG) --keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple $(DMG)
endif
	@echo "Built $(DMG)"

# A release: always Developer ID signed and notarized, or it fails. `make dmg` alone
# stays the ad-hoc developer build. The short name works while the keychain holds one
# Developer ID Application identity; else pass RELEASE_SIGN_ID with the full name.
RELEASE_SIGN_ID ?= Developer ID Application
RELEASE_NOTARY_PROFILE ?= roamrun-notary
# Built under a -pending name; the release name appears only once every check passed.
PENDING_DMG = $(APP_NAME)-$(VERSION)-pending.dmg
# The tag must name the commit the dmg is built from (AGENTS.md), so it needs git to say which.
release-dmg:
	@git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { \
		echo "not a git checkout — release from a fresh clone (AGENTS.md)"; exit 1; }
	@if [ -n "$$(git status --porcelain)" ]; then \
		echo "working tree has uncommitted changes — release from a fresh clone (AGENTS.md)"; exit 1; fi
	@t=$$(git rev-parse -q --verify "refs/tags/v$(VERSION)^{commit}"); \
	if [ -n "$$t" ] && [ "$$t" != "$$(git rev-parse HEAD)" ]; then \
		echo "tag v$(VERSION) is on $$t, not on HEAD — check out that commit or bump the version"; exit 1; fi
	rm -f $(DMG) $(PENDING_DMG)
	$(MAKE) dmg DMG="$(PENDING_DMG)" SIGN_ID="$(RELEASE_SIGN_ID)" NOTARY_PROFILE="$(RELEASE_NOTARY_PROFILE)"
	xcrun stapler validate $(BUNDLE)
	xcrun stapler validate $(PENDING_DMG)
	spctl -a -vv -t exec $(BUNDLE) 2>&1 | grep -q "source=Notarized Developer ID"
	mv $(PENDING_DMG) $(DMG)
	@echo "Release $(DMG) is signed, notarized and stapled, built from $$(git rev-parse HEAD) (gh release create --target)"

# `roamrun` on PATH, pointing into the app bundle (one binary for app + CLI).
BINDIR ?= /usr/local/bin
install-cli: app
	@t="$(BINDIR)/roamrun"; \
	if { [ -e "$$t" ] || [ -L "$$t" ]; } && ! { [ -L "$$t" ] && readlink "$$t" | grep -q '/RoamRun$$'; }; then \
		echo "$$t exists and is not a RoamRun link — not touching it"; exit 1; fi
	@[ -d "$(BINDIR)" ] || { echo "$(BINDIR) doesn't exist — create it (sudo mkdir -p $(BINDIR)) or pass BINDIR=$$HOME/bin"; exit 1; }
	ln -sfh "$(CURDIR)/$(BUNDLE)/Contents/MacOS/$(APP_NAME)" "$(BINDIR)/roamrun"
	@echo "Installed $(BINDIR)/roamrun"

# Regenerate Resources/AppIcon.icns from scripts/make-icon.swift.
icon:
	rm -rf .build/AppIcon.iconset
	xcrun swift scripts/make-icon.swift .build/AppIcon.iconset
	iconutil -c icns .build/AppIcon.iconset -o Resources/AppIcon.icns
	mkdir -p docs
	cp .build/AppIcon.iconset/icon_256x256@2x.png docs/icon.png

clean:
	rm -rf .build $(BUNDLE) dmg-root $(APP_NAME)-*.dmg $(APP_NAME)-notarize.zip
