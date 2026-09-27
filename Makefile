EXEC     := Mulligan
APPNAME  := Mulligan.app
# `build` and `test` stay debug for fast iteration; the shipped bundle is release.
CONFIG   := debug
APP_CONFIG := release

# Build products and the staged bundle live outside the repo. This keeps the tree clean
# and avoids ever building inside a cloud-synced folder, where a sync engine can touch
# object files mid-compile or stamp extended attributes onto the bundle that codesign
# refuses.
#
# A linked worktree (`.git` is a file, not a directory) gets its own stage under
# worktrees/<name>, so parallel builds never share SwiftPM state or clobber each other's
# bundle. Only the main checkout owns the canonical stage, and only the canonical stage may
# be launched or installed: every opened copy of Mulligan.app registers itself with
# LaunchServices under the same bundle id, and while the Accessibility grant is missing
# each one pops the system prompt.
CANONICAL_STAGE := $(HOME)/Library/Caches/MulliganBuild
IS_WORKTREE     := $(shell test -f .git && echo 1)
ifeq ($(IS_WORKTREE),1)
STAGE    := $(CANONICAL_STAGE)/worktrees/$(notdir $(CURDIR))
else
STAGE    := $(CANONICAL_STAGE)
endif
SCRATCH    := $(STAGE)/scratch
BUILD      := $(SCRATCH)/$(CONFIG)/$(EXEC)
APP_BUILD  := $(SCRATCH)/$(APP_CONFIG)/$(EXEC)
BUNDLE     := $(STAGE)/$(APPNAME)
CONTENTS   := $(BUNDLE)/Contents
INSTALLED  := /Applications/$(APPNAME)
# The app was called Sotto until 0.2.1. Same bundle id, so a leftover copy would register
# alongside the new one and could take the push-to-talk key: install removes it.
LEGACY_INSTALLED := /Applications/Sotto.app
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# TCC keys the Accessibility and Microphone grants to the code signature. An ad-hoc
# signature changes on every build, which silently invalidates the grant while the toggle
# in System Settings still shows as on. A Developer ID keeps the identity stable across
# rebuilds, so `app` refuses to sign without one instead of falling back. SIGN_ID=- on
# the command line forces a throwaway ad-hoc build; it will prompt again on every rebuild.
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null \
	         | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/')

# Release artefacts. VERSION is read from Info.plist so the tag, the zip name and the
# bundle never disagree. NOTARY_PROFILE names the keychain item created once with
# `xcrun notarytool store-credentials`; see the `notary-profile` target.
VERSION        := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
# The keychain item predates the rename to Mulligan and keeps its name.
NOTARY_PROFILE ?= sotto-notary
DIST           := $(STAGE)/dist
ZIP            := $(DIST)/Mulligan-$(VERSION).zip

.PHONY: all build test app run install clean icon signing-identity launchable \
        notary-profile notarize release

all: app

build:
	swift build -c $(CONFIG) --scratch-path "$(SCRATCH)"

test:
	swift test --scratch-path "$(SCRATCH)"

signing-identity:
	@if [ -z "$(strip $(SIGN_ID))" ]; then \
	    echo "error: no Developer ID Application identity in the keychain; refusing to sign ad-hoc." >&2; \
	    echo "       An ad-hoc signature changes every build and resets the Accessibility grant." >&2; \
	    echo "       Unlock the login keychain and retry, or pass SIGN_ID=- for a throwaway build." >&2; \
	    exit 1; \
	fi

# Launching and installing are allowed only from the main checkout's canonical stage.
launchable:
	@if [ "$(STAGE)" != "$(CANONICAL_STAGE)" ]; then \
	    echo "error: run and install work only from the main checkout with the default STAGE." >&2; \
	    echo "       This is a worktree or an overridden STAGE: build and test here, launch from the main checkout." >&2; \
	    exit 1; \
	fi

# TCC needs a real bundle with a stable identifier; the bare SwiftPM binary is not enough.
app: signing-identity
	swift build -c $(APP_CONFIG) --scratch-path "$(SCRATCH)"
	@rm -rf "$(BUNDLE)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	@cp "$(APP_BUILD)" "$(CONTENTS)/MacOS/$(EXEC)"
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$(CONTENTS)/Resources/"; fi
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@xattr -cr "$(BUNDLE)"
	@codesign --force --sign "$(SIGN_ID)" \
	    --entitlements Resources/$(EXEC).entitlements \
	    --options runtime \
	    --timestamp=none \
	    "$(BUNDLE)"
	@echo "built $(BUNDLE)  [signed: $(SIGN_ID), config: $(APP_CONFIG)]"

run: launchable app
	@pkill -x $(EXEC) 2>/dev/null || true
	@open "$(BUNDLE)"

# The staged copy is unregistered afterwards so LaunchServices resolves the bundle id to
# the installed app alone. lsregister -u exits 1 (-10814) when the path was never
# registered, which is the normal case after a plain `make app`, hence the `|| true`.
install: launchable app
	@pkill -x $(EXEC) 2>/dev/null || true
	@pkill -x Sotto 2>/dev/null || true
	@if [ -d "$(LEGACY_INSTALLED)" ]; then \
	    "$(LSREGISTER)" -u "$(LEGACY_INSTALLED)" >/dev/null 2>&1 || true; \
	    rm -rf "$(LEGACY_INSTALLED)"; \
	    echo "removed the old $(LEGACY_INSTALLED)"; \
	fi
	@rm -rf "$(INSTALLED)"
	@cp -R "$(BUNDLE)" "$(INSTALLED)"
	@"$(LSREGISTER)" -u "$(BUNDLE)" >/dev/null 2>&1 || true
	@"$(LSREGISTER)" -f "$(INSTALLED)"
	@open "$(INSTALLED)"
	@echo "installed to $(INSTALLED)"

## Regenerates the app icon from Tools/makeicon.swift. Not a dependency of `app`: the icon
## rarely changes and rendering ten PNGs on every build is wasted time.
## After changing the icon, bump CFBundleVersion in Resources/Info.plist: the icon service
## caches per bundle identity and version, and the Dock keeps the old tile otherwise.
icon:
	@swift Tools/makeicon.swift
	@iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
	@echo "wrote Resources/AppIcon.icns"

## Release: notarise the signed bundle and publish it as a GitHub release.
##
## `app` signs without a timestamp so offline builds work; notarisation requires a secure
## timestamp, so `notarize` re-signs the same bundle with one (same identity, so the
## Accessibility grant is unaffected), zips it with ditto (the only zip Gatekeeper accepts
## for bundles), submits it, staples the ticket into the bundle and zips again so the
## download carries the ticket offline. `spctl` runs the same assessment Gatekeeper does on
## first open, so a failure here is a failure the user would have seen.
notary-profile:
	@if ! xcrun notarytool history --keychain-profile "$(NOTARY_PROFILE)" >/dev/null 2>&1; then \
	    echo "error: no notarytool credentials named '$(NOTARY_PROFILE)' in the keychain." >&2; \
	    echo "       Create them once (prompts for an app-specific password):" >&2; \
	    echo "       xcrun notarytool store-credentials $(NOTARY_PROFILE) --apple-id <apple-id> --team-id <team-id>" >&2; \
	    exit 1; \
	fi

notarize: launchable notary-profile app
	@codesign --force --sign "$(SIGN_ID)" \
	    --entitlements Resources/$(EXEC).entitlements \
	    --options runtime \
	    --timestamp \
	    "$(BUNDLE)"
	@mkdir -p "$(DIST)"
	@rm -f "$(ZIP)"
	@ditto -c -k --keepParent "$(BUNDLE)" "$(ZIP)"
	@echo "submitting $(notdir $(ZIP)) for notarisation (this waits for Apple)..."
	@xcrun notarytool submit "$(ZIP)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	@xcrun stapler staple "$(BUNDLE)"
	@xcrun stapler validate "$(BUNDLE)"
	@spctl --assess --type execute --verbose=2 "$(BUNDLE)"
	@rm -f "$(ZIP)"
	@ditto -c -k --keepParent "$(BUNDLE)" "$(ZIP)"
	@echo "notarised $(ZIP)"

# Refuses to publish over an existing tag; bump CFBundleShortVersionString first.
release: notarize
	@if git rev-parse -q --verify "refs/tags/v$(VERSION)" >/dev/null; then \
	    echo "error: tag v$(VERSION) already exists; bump the version in Resources/Info.plist." >&2; \
	    exit 1; \
	fi
	@if [ -n "$$(git status --porcelain)" ]; then \
	    echo "error: working tree is not clean; commit or stash before releasing." >&2; \
	    exit 1; \
	fi
	@git tag -a "v$(VERSION)" -m "Mulligan $(VERSION)"
	@git push origin "v$(VERSION)"
	@gh release create "v$(VERSION)" "$(ZIP)" --title "Mulligan $(VERSION)" --generate-notes
	@echo "published v$(VERSION)"

# From the main checkout this also removes every worktree stage under $(STAGE)/worktrees.
clean:
	@if [ -d "$(BUNDLE)" ]; then "$(LSREGISTER)" -u "$(BUNDLE)" >/dev/null 2>&1 || true; fi
	@rm -rf .build "$(STAGE)"
