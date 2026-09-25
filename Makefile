APP = Flash.app
BINARY = .build/release/Flash

build:
	swift build -c release

# Re-render Resources/logo.png + Resources/Flash.icns from Resources/logo.svg.
# Both outputs are committed, so plain builds never need this.
# Needs: npm i --no-save playwright-core (uses your installed Chrome).
icon:
	node tools/render-logo.mjs

bundle: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BINARY) $(APP)/Contents/MacOS/Flash
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $$(date +%Y%m%d%H%M%S)" $(APP)/Contents/Info.plist
	cp Resources/Flash.icns $(APP)/Contents/Resources/Flash.icns
	cp tools/git-ssh-keygen-flash tools/flash-notify tools/flash-askpass $(APP)/Contents/Resources/
	cp -R tools/git-hooks $(APP)/Contents/Resources/git-hooks
	codesign --force --sign - $(APP)
	@echo "build $$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' $(APP)/Contents/Info.plist)"

# Run from terminal so sniffer logs land in stdout — best for testing.
run: bundle
	$(APP)/Contents/MacOS/Flash

open-app: bundle
	open $(APP)

# Install as a real app — no terminal needed after this.
install: bundle
	pkill -x Flash || true
	rm -rf /Applications/Flash.app
	cp -R $(APP) /Applications/$(APP)
	touch /Applications/$(APP)
	@echo "Installed to /Applications/Flash.app — open it once, then enable Launch at login in Settings."

# Universal, signed (+ notarized if configured) dmg/zip in dist/. See tools/release.sh.
release:
	tools/release.sh

# Same, then creates the GitHub release for the Info.plist version (needs gh).
publish:
	tools/release.sh --publish

# One-shot: upload signing / notary / tap secrets to GitHub via gh (interactive).
release-secrets:
	tools/setup-release-secrets.sh

# Render the Homebrew cask for the built release (dist/ must exist). CI publishes it.
cask:
	tools/update-cask.sh --print

# Guided test of every detection path (needs Flash running). Step N only: make selftest STEP=N
selftest:
	tools/flash-selftest $(STEP)

clean:
	rm -rf .build $(APP) dist

.PHONY: build bundle run open-app icon release publish release-secrets cask selftest clean
