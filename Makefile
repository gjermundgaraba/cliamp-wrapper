INSTALL_DIR ?= /Applications

.PHONY: all ghosttykit build app install run clean distclean

all: app

# Build libghostty (full embedder API) from the Ghostty submodule. Zig caches
# the work, so this is a few seconds when nothing changed.
ghosttykit:
	scripts/build-ghosttykit.sh

# Compile the Swift app only (no bundle).
build: ghosttykit
	swift build -c release --product CliampWrapper

# Assemble build/Cliamp.app.
app: ghosttykit
	scripts/bundle-app.sh

# Copy build/Cliamp.app into $(INSTALL_DIR), replacing any previous copy.
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
