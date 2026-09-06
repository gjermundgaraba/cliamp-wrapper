# cliamp-wrapper

A native macOS app that runs [cliamp](https://github.com/bjarneo/cliamp)
inside an embedded [Ghostty](https://ghostty.org) terminal. Written in
Swift/AppKit for macOS 26 on Apple Silicon. Ghostty is built from the revision
pinned by the `vendor/ghostty` submodule; cliamp is installed separately.

## Requirements

- macOS 26, Xcode 26 with the Metal toolchain
- Zig 0.16.x on `PATH` (see [Ghostty's version requirement](vendor/ghostty/build.zig.zon))
- `cliamp` installed (`brew install bjarneo/cliamp/cliamp` or `~/.local/bin/cliamp`)

## Build

```sh
make app       # builds GhosttyKit and build/Cliamp.app
make run       # builds and opens the app
swift test     # requires GhosttyKit from the build above
```

The build initializes the Ghostty submodule if needed. The app includes its
icon, terminfo and Ghostty resources, and is ad-hoc signed. Set `VERSION` and
`BUILD_NUMBER` to override the bundle version fields.

| Target | What it does |
|--------|--------------|
| `make ghosttykit` | Builds `vendor/ghostty/macos/GhosttyKit.xcframework` for the host architecture. |
| `make build` | Builds GhosttyKit and the release executable without an app bundle. |
| `make install` | Builds and copies the app into `/Applications` (override with `INSTALL_DIR=~/Applications`). |
| `make clean` | Removes Swift build output and the app bundle. |
| `make distclean` | Also removes Ghostty build output, Zig caches and the xcframework. |

## Running cliamp

The wrapper searches `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`,
then `PATH`. Set `CLIAMP_WRAPPER_EXEC` to use a specific executable:

```sh
CLIAMP_WRAPPER_EXEC=/path/to/cliamp build/Cliamp.app/Contents/MacOS/Cliamp
```

Search paths and the override expand `~` and resolve relative to the wrapper's
launch directory. Empty `PATH` entries refer to that directory. The child gets
the same normalized search path and starts in the user's home directory.

A shell launcher records cliamp's exit status in a temporary file. Status 0
quits the app; other or unavailable statuses leave the output visible with a
banner until a key is pressed.

## Configuration

Edit [Resources/ghostty.conf](Resources/ghostty.conf) (rebuild) or create
`~/.config/cliamp-wrapper/ghostty.conf` (no rebuild). Options that libghostty
itself implements work, for example `font-family`, `font-size`, `theme`,
`window-padding-*`, and `config-file` to pull in more files. Options that
only Ghostty's own app implements (tabs, splits, window state, initial
window size) have no effect; the window remembers its last frame instead.

The command is set on the surface. Config-file `command` settings are ignored;
`initial-command` must not be set.

Default Ghostty keybindings are cleared. Copy, paste, select all, font size and
full screen are menu items with the usual shortcuts.

Light/dark theme pairs (`theme = light:…,dark:…`) follow the system appearance.
The titlebar follows the terminal background. Config files are
loaded at launch; appearance changes reapply that config without rereading files.

Links in terminal output open on Cmd+click only for `http`, `https` and
`mailto` targets; file paths, other schemes, and the `write_*_file:open`
keybind actions are dropped.

Clipboard requests that would need a confirmation dialog are refused, so keep
`clipboard-read`, `clipboard-write` and `clipboard-paste-protection` set to
definite values rather than `ask`. The bundled config denies program-initiated
clipboard reads and allows writes.

## Updating Ghostty

```sh
git -C vendor/ghostty fetch --depth 1 origin main
git -C vendor/ghostty checkout FETCH_HEAD
make app
```

The embedder API is unstable. Its declarations are in
[ghostty.h](vendor/ghostty/include/ghostty.h); updating the submodule may require
changes to the Swift callbacks.

## Source layout

- [AppDelegate.swift](Sources/CliampWrapper/AppDelegate.swift): window, menus and app lifecycle.
- [GhosttyHost.swift](Sources/CliampWrapper/GhosttyHost.swift): libghostty ownership, configuration and runtime callbacks.
- [TerminalView.swift](Sources/CliampWrapper/TerminalView.swift), [Input.swift](Sources/CliampWrapper/Input.swift) and [Clipboard.swift](Sources/CliampWrapper/Clipboard.swift): rendering surface and input integration.
- [CommandResolver.swift](Sources/CliampWrapper/CommandResolver.swift): executable lookup and launcher.
- [WrapperConfig.swift](Sources/CliampWrapper/WrapperConfig.swift): app defaults.
- [TitleToolbar.swift](Sources/CliampWrapper/TitleToolbar.swift): centered window title.
- [scripts/](scripts/): GhosttyKit build and app packaging; [Package.swift](Package.swift) links the xcframework.
- [Tests/](Tests/): command lookup, modifier handling and theme tests.

## License

MIT. The app icon is cliamp's own artwork, also MIT.
