APP_NAME := Nits
BUNDLE_ID := app.nits.macos
BUILD_DIR := .build
CONFIG ?= release
APP := dist/$(APP_NAME).app

.PHONY: all build app run test check clean install install-cli uninstall

all: app

build:
	swift build -c $(CONFIG)

test:
	swift run -c debug NitsSelfTest

check: test
	swift build -c $(CONFIG)

app:
	./scripts/build-app.sh $(CONFIG)

run: app
	open $(APP)

install: app
	rm -rf /Applications/$(APP_NAME).app
	cp -R $(APP) /Applications/
	@echo "Installed /Applications/$(APP_NAME).app"

install-cli: app
	mkdir -p $(HOME)/.local/bin
	ln -sf "$(CURDIR)/$(APP)/Contents/MacOS/nitsctl" $(HOME)/.local/bin/nitsctl
	@echo "Linked $(HOME)/.local/bin/nitsctl -> Nits.app/Contents/MacOS/nitsctl"
	@echo "Ensure $(HOME)/.local/bin is on PATH."

uninstall:
	rm -rf /Applications/$(APP_NAME).app
	rm -f $(HOME)/.local/bin/nitsctl
	@echo "Removed /Applications/$(APP_NAME).app and the CLI link"

clean:
	rm -rf .build dist
