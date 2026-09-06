# cliamp-wrapper

A native macOS app that runs [cliamp](https://github.com/bjarneo/cliamp)
inside an embedded [Ghostty](https://ghostty.org) terminal. The app is a
small Swift/AppKit shell around `libghostty` (the full embedder API: VT core,
Metal renderer, PTY, input encoding).

libghostty is built from Ghostty `main` on purpose: the embedder API is still
unstable and the prebuilt packages track older tagged releases. Targets
macOS 26 on Apple Silicon only.

## Requirements

- macOS 26, Xcode 26 with the Metal toolchain
- Zig 0.16.x (`brew install zig`); Ghostty main pins the exact minor and its build says so if yours differs
- `cliamp` installed (`brew install bjarneo/cliamp/cliamp` or `~/.local/bin/cliamp`)

The build uses `zig` from PATH. If multiple versions are installed, put the
required version first and confirm with `zig version`.

## Build

```sh
git submodule update --init --depth 1   # vendor/ghostty
make app                                # libghostty, the Swift app, build/Cliamp.app
make run
swift test                              # focused Swift tests (requires GhosttyKit)
```

| Target | What it does |
|--------|--------------|
| `make ghosttykit` | `zig build -Doptimize=ReleaseFast -Demit-macos-app=false -Dxcframework-target=native` in `vendor/ghostty`, producing `macos/GhosttyKit.xcframework`. About 3 minutes cold, a few seconds when nothing changed. |
| `make build` | checks GhosttyKit is current, then `swift build -c release` (no bundle) |
| `make app` | assembles `build/Cliamp.app` with icon, terminfo, themes and an ad-hoc signature (`VERSION` and `BUILD_NUMBER` env vars are honoured) |
| `make install` | copies the app into `/Applications` (override with `INSTALL_DIR=~/Applications`) |
| `make distclean` | removes Zig caches and the xcframework |

## How it works

- `scripts/build-ghosttykit.sh` builds Ghostty's C library as an xcframework;
  `Package.swift` links it as a binary target.
- `GhosttyHost.swift` initialises libghostty, loads `Resources/ghostty.conf`
  (plus `~/.config/cliamp-wrapper/ghostty.conf` if present), creates the app
  and the single surface with the launcher as its command, and implements
  the runtime callbacks (wakeup, actions, clipboard, close). The command is
  set on the surface; `command` in a config file is ignored, and
  `initial-command` is reserved and must not be set.
- `TerminalView.swift` is the NSView libghostty renders into. It forwards
  keys (including IME, dead keys and command-chord releases), mouse, scroll,
  focus, size and scale the same way Ghostty's own macOS app does.
- `CommandResolver.swift` finds cliamp in `~/.local/bin`, `/opt/homebrew/bin`,
  `/usr/local/bin`, then `PATH`. `CLIAMP_WRAPPER_EXEC=/path/to/binary` is
  used instead; a bad path fails visibly inside the terminal. Search directories
  and the override are normalized to absolute paths relative to the wrapper's
  launch directory, with `~` expanded. Empty `PATH` entries mean that directory.
  The child receives the same normalized, deduplicated search directories in
  `PATH`, so a different terminal working directory does not change lookup.
- The command is a short `sh` launcher that runs cliamp and writes its exit
  status to a temp file. Ghostty on macOS runs commands under `/usr/bin/login`,
  which always exits 0, so this is the only way to know how cliamp ended.
  Status 0 quits the app; anything else keeps the output visible and shows a
  banner until a key is pressed.

## Configuration

Edit `Resources/ghostty.conf` (rebuild) or create
`~/.config/cliamp-wrapper/ghostty.conf` (no rebuild). Options that libghostty
itself implements work, for example `font-family`, `font-size`, `theme`,
`window-padding-*`, and `config-file` to pull in more files. Options that
only Ghostty's own app implements (tabs, splits, window state, initial
window size) have no effect; the window remembers its last frame instead.

Default keybinds are cleared so cliamp sees every key. Copy, paste, select
all, font size and full screen are menu items with the usual shortcuts.

Light/dark theme pairs (`theme = light:…,dark:…`) follow the system appearance.
The titlebar follows the terminal background for contrast. Config files are
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

libghostty's embedder API is not stable. If the build breaks after an update,
compare `vendor/ghostty/include/ghostty.h` against the callbacks in
`GhosttyHost.swift`, `Clipboard.swift` and `TerminalView.swift`.

See `docs/ghostty-wrapper-research.md` for the survey of alternative
approaches (libghostty-spm, Trolley, driving Ghostty.app directly).

## License

MIT. The app icon is cliamp's own artwork, also MIT.
