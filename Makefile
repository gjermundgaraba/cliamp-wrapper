INSTALL_DIR ?= /Applications

.PHONY: all ghosttykit build app install run clean distclean

all: app

# Zig caches its work, so this takes a few seconds when nothing changed.
ghosttykit:
	scripts/build-ghosttykit.sh

build: ghosttykit
	swift build -c release --product CliampWrapper

app: ghosttykit
	scripts/bundle-app.sh

install: app
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALL_DIR)/Cliamp.app"
	cp -R build/Cliamp.app "$(INSTALL_DIR)/Cliamp.app"
	@echo "installed $(INSTALL_DIR)/Cliamp.app"

run: app
	open build/Cliamp.app

clean:
	rm -rf .build build

distclean: clean
	rm -rf vendor/ghostty/zig-out vendor/ghostty/.zig-cache vendor/ghostty/macos/GhosttyKit.xcframework
