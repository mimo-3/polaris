.PHONY: build test app snapshots install
build:
	swift build

test:
	./scripts/test.sh

app:
	./scripts/bundle.sh

snapshots: app
	build/Polaris.app/Contents/MacOS/Polaris --render-snapshots snapshots/

install: app
	rm -rf /Applications/Polaris.app
	cp -R build/Polaris.app /Applications/Polaris.app
