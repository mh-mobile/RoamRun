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

.PHONY: all build app run dmg icon install-cli test clean

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
