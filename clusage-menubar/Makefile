build:
	swift build

test:
	swift run ClusageTests

lint:
	shellcheck build.sh make_icon.sh create_dmg.sh release.sh

check: build test lint

app:
	./build.sh

dmg: app
	./create_dmg.sh

.PHONY: build test lint check app dmg
