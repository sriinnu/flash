APP = Flash.app
BINARY = .build/release/Flash

build:
	swift build -c release

Resources/Flash.icns: tools/render_icon.swift
	swift tools/render_icon.swift
	rm -rf build/Flash.iconset
	mkdir -p build/Flash.iconset
	sips -z 16 16     build/icon-1024.png --out build/Flash.iconset/icon_16x16.png
	sips -z 32 32     build/icon-1024.png --out build/Flash.iconset/icon_16x16@2x.png
	sips -z 32 32     build/icon-1024.png --out build/Flash.iconset/icon_32x32.png
	sips -z 64 64     build/icon-1024.png --out build/Flash.iconset/icon_32x32@2x.png
	sips -z 128 128   build/icon-1024.png --out build/Flash.iconset/icon_128x128.png
	sips -z 256 256   build/icon-1024.png --out build/Flash.iconset/icon_128x128@2x.png
	sips -z 256 256   build/icon-1024.png --out build/Flash.iconset/icon_256x256.png
	sips -z 512 512   build/icon-1024.png --out build/Flash.iconset/icon_256x256@2x.png
	sips -z 512 512   build/icon-1024.png --out build/Flash.iconset/icon_512x512.png
	sips -z 1024 1024 build/icon-1024.png --out build/Flash.iconset/icon_512x512@2x.png
	iconutil -c icns build/Flash.iconset -o Resources/Flash.icns

icon: Resources/Flash.icns

bundle: build Resources/Flash.icns
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BINARY) $(APP)/Contents/MacOS/Flash
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $$(date +%Y%m%d%H%M%S)" $(APP)/Contents/Info.plist
	cp Resources/Flash.icns $(APP)/Contents/Resources/Flash.icns
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

clean:
	rm -rf .build $(APP) dist

.PHONY: build bundle run open-app release publish clean
