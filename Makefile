.PHONY: build test app release snapshots install
build:
	swift build

test:
	./scripts/test.sh

app:
	./scripts/bundle.sh

snapshots: app
	build/Polaris.app/Contents/MacOS/Polaris --render-snapshots snapshots/

install: app
	./scripts/install.sh

release:
	./scripts/release.sh
