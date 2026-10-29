# Wraps the SwiftPM binary in an app bundle so macOS treats it as a menu bar agent.
APP = build/Mindmap.app
BIN = .build/release/Mindmap

.PHONY: app run clean

app:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BIN) $(APP)/Contents/MacOS/Mindmap
	cp Info.plist $(APP)/Contents/Info.plist
	cp -R .build/release/Mindmap_Mindmap.bundle $(APP)/Contents/Resources/ 2>/dev/null || true
	cp -R .build/release/Harness_Harness.bundle $(APP)/Contents/Resources/ 2>/dev/null || true
	@echo "built $(APP)"

run: app
	open $(APP)

clean:
	rm -rf build .build
