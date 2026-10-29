# Builds the menu bar app bundle (build/Mindmap.app) for this Mac's chip with ../scripts/build-app.sh,
# the same script GitHub Actions runs for releases.
APP = build/Mindmap.app

.PHONY: app run clean

app:
	UNIVERSAL=0 ../scripts/build-app.sh

run: app
	open $(APP)

clean:
	rm -rf build .build
