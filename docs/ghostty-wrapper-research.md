# Wrapping a TUI app in a Ghostty / libghostty shell on macOS

Research snapshot: 2026-09-01. Local toolchain at time of writing: Ghostty 1.3.1
(stable), Zig 0.15.2, Xcode 26.6, macOS 26.6.2.

## Outcome

Route 3 was implemented in this repo: `GhosttyKit.xcframework` built from
Ghostty `main` (Zig 0.16) plus a Swift/AppKit shell, targeting macOS 26.
See the README for build instructions. The notes below are the survey that
led to that choice.

## TL;DR

There are four realistic routes. Ranked for "ship a dedicated .app that runs one
TUI and nothing else":

| # | Route | Effort | Control | Status / risk |
|---|-------|--------|---------|---------------|
| 1 | Own Swift app + `libghostty-spm` (prebuilt GhosttyKit + `GhosttyTerminal` views) | Low | High | Third-party package, tracks Ghostty 1.3.1, MIT. Best default. |
| 2 | Trolley (`trolley.toml` → .app/.dmg, signed + notarized) | Very low | Medium | Purpose-built for exactly this. Self-described pre-alpha. |
| 3 | Own Swift app + self-built `GhosttyKit.xcframework` from upstream | Medium | Highest | Same C API as (1) but you own the build and the AppKit glue (estimated ~600 lines; about 1,500 as built). Unstable API. |
| 4 | Launcher .app that drives the installed Ghostty.app (`open --args` or AppleScript) | Trivial | Low | Requires user to have Ghostty installed. Not a real wrapper. |

Not recommended right now: building on `libghostty-vt` (headless, no renderer,
no PTY) or forking Ghostty's full macOS app. Mitchell announced a pure-Swift
Metal renderer package for libghostty-vt in July 2026; it has not shipped as
of this writing, so re-check before revisiting route 3.

## State of libghostty (Sept 2026)

- Ghostty's core is a C-ABI static library. The **full embedder API**
  (`include/ghostty.h`, ~1280 lines) exposes app/config/surface creation, a
  Metal renderer that draws into your `NSView`'s `CAMetalLayer`, PTY spawning,
  key/mouse/IME encoding, clipboard callbacks and an "action" callback for
  everything UI-level (title, bell, resize hints, child exited, quit).
  Official docs still say it is *not stable* and "may change significantly
  between releases". Real-world reports: enum constants renumbered between
  releases, which compiles silently in Swift.
- **libghostty-vt** (`include/ghostty/vt.h`) is the officially promoted,
  zero-dependency library. It is only the VT state machine: no rendering, no
  PTY, no font handling. Upstream now publishes a universal
  `ghostty-vt.xcframework` on every tip build, but that does not help a TUI
  wrapper unless you bring your own renderer.
- Ghostty's own macOS app is Swift/AppKit linking `GhosttyKit.xcframework`,
  which `zig build` writes to `macos/GhosttyKit.xcframework`. On macOS the
  default app runtime is `none`, so a plain `zig build` produces exactly that
  xcframework (plus the app unless you pass `-Demit-macos-app=false`).
- The ecosystem is large (100+ projects in awesome-libghostty). Most macOS
  apps use either `libghostty-spm` or a self-built xcframework and write an
  NSView subclass. Several of them (Sessylph, macterm, justty, supacode,
  cmux, Trolley) are good reference code.

## Route 1: Swift app + libghostty-spm (recommended)

Package: https://github.com/Lakr233/libghostty-spm (MIT).

- Products: `GhosttyKit` (raw C API), `GhosttyTerminal` (Swift views:
  `TerminalSurfaceView` for SwiftUI, `AppTerminalView` for AppKit, plus
  `TerminalController`, display link, input, IME), `GhosttyTheme` (485
  iTerm2 schemes).
- Binary target is a prebuilt `GhosttyKit.xcframework` pinned to upstream
  1.3.1 (`upstream.1.3.1-2` release). Platforms: macOS 13+, iOS 15+.
- `TerminalSurfaceOptions` maps straight onto `ghostty_surface_config_s`:

  ```swift
  TerminalSurfaceOptions(
      backend: .exec,                      // real PTY, spawns the command
      fontSize: 14,
      workingDirectory: "/path",
      envVars: ["MYAPP_MODE": "gui"],
      command: "direct:/path/to/my-tui --flag",
      waitAfterCommand: false
  )
  ```

  `.exec` is the default backend and spawns a local PTY exactly like
  upstream. `.inMemory(session)` exists for sandboxed apps where you feed
  bytes yourself.
- Trimmed relative to upstream: no custom GLSL shaders, no ImGui inspector,
  no Sentry. Everything a TUI needs (VT core, Metal renderer, CoreText fonts,
  config system, input, selection/clipboard) is retained. It bundles the
  `xterm-ghostty` terminfo and its own MIT bash/zsh shell integration.
- Practical shape of the app: one `NSWindow`, one `AppTerminalView` (or a
  SwiftUI `TerminalSurfaceView`), `TerminalController(configFilePath:)`
  pointing at a bundled Ghostty config, delegate callbacks for title and
  process exit. Disable App Sandbox (PTY spawning needs it off).

## Route 2: Trolley

Repo: https://github.com/weedonandscott/trolley (MIT, "pre-alpha,
functionality and design expected to be broken"). Install:
`brew install weedonandscott/tap/trolley`.

- You write a `trolley.toml` with `[app]` (id, name, slug, version, icons),
  `[macos] binaries = { aarch64 = "path/to/tui" }`, optional `[gui]` window
  size/resizable/min/max, `[fonts]` (auto-downloads Nerd Fonts), `[embeds]`
  (themes, shaders, data files), `[environment]`, and a `[ghostty]`
  passthrough table for any scalar Ghostty config key.
- `trolley run` for local testing, `trolley package` for `.app`, `.dmg`,
  `.tar.gz`. Handles Developer ID signing, hardened runtime, notarization and
  stapling from env vars. Also produces Linux (AppImage/deb/rpm) and Windows
  (NSIS) from the same manifest.
- The macOS runtime is an ~800-line Swift/AppKit/Metal program that does the
  minimal libghostty dance: `ghostty_init` → `ghostty_config_load_file` on a
  bundled `ghostty.conf` → `ghostty_app_new` with six callbacks → one
  `NSWindow` + `NSView` → `ghostty_surface_new`. libghostty is built from a
  pinned Ghostty submodule with `-Dapp-runtime=none -Drenderer=metal
  -Dfont-backend=coretext`, fat-archived with `libtool`, and linked into a
  SwiftPM executable. The prebuilt runtime ships with the CLI, so end users
  of the tool need neither Zig nor Xcode.
- Limits: single window, no tabs/splits; command arguments cannot contain
  whitespace (use `[ghostty].command` for quoting); no sandboxing; pre-alpha
  churn. Even if you do not adopt it, `runtime/macos/Sources/main.swift` is
  the best minimal reference for route 3.

## Route 3: Self-built GhosttyKit.xcframework + your own AppKit glue

Use this if you need to pin a specific upstream commit, apply patches, or
avoid a third-party binary.

Build (Ghostty 1.3.x wants Zig 0.15.2; main wants Zig 0.16.0 and Xcode 26):

```sh
git clone https://github.com/ghostty-org/ghostty && cd ghostty
git checkout v1.3.1                      # or stay on main
zig build -Doptimize=ReleaseFast -Demit-macos-app=false \
          -Dxcframework-target=native    # drop for a universal build
# => macos/GhosttyKit.xcframework  (ghostty.h + module.modulemap + a static archive)
# => zig-out/share/terminfo, shell-integration, themes (bundle if you need them)
```

Drag the xcframework into an Xcode app target (or wrap it as a SwiftPM
`binaryTarget`). Then implement, roughly in this order:

1. `ghostty_init(argc, argv)`, `ghostty_config_new`, `ghostty_config_load_file`
   (a config you ship in the bundle), `ghostty_config_finalize`.
2. `ghostty_runtime_config_s` with `wakeup_cb` (schedule `ghostty_app_tick`
   on main), `action_cb` (handle `SET_TITLE`, `INITIAL_SIZE`, `SIZE_LIMIT`,
   `SHOW_CHILD_EXITED`, `CLOSE_WINDOW`, `QUIT`, ignore the rest), clipboard
   read/write/confirm, and `close_surface_cb`. `ghostty_app_new`.
3. An `NSView` subclass with `wantsLayer = true` and a `CAMetalLayer` backing
   layer. Fill `ghostty_surface_config_s` (`platform_tag = MACOS`,
   `platform.macos.nsview`, `scale_factor`, `font_size`, `working_directory`,
   `command`, `env_vars`, `initial_input`, `wait_after_command`, `context`) and
   call `ghostty_surface_new`.
4. Forward `keyDown/keyUp/flagsChanged` → `ghostty_surface_key`,
   `insertText` → `ghostty_surface_text`, mouse → `ghostty_surface_mouse_*`,
   `setFrameSize`/`viewDidChangeBackingProperties` →
   `ghostty_surface_set_size` / `set_content_scale`, focus →
   `ghostty_surface_set_focus`, drawing via a `CVDisplayLink` or
   `ghostty_surface_draw` on wakeup.

Reference implementations: Ghostty's `macos/Sources/Ghostty/` (App.swift,
Surface View/SurfaceView_AppKit.swift), Trolley's `runtime/macos`,
`0x96f/justty`, `thdxg/macterm` (its AGENTS.md documents the ABI pitfalls).

Cost: the static archive is large (about 129 MiB for an arm64 ReleaseFast build of
main; it varies by revision and target); expect to re-verify the
`ghostty_action_tag_e` enum and struct layouts on every upstream bump.

## Route 4: Launcher around the installed Ghostty.app

Zero code, but the user must have Ghostty installed and the window is a
normal Ghostty window (Ghostty dock icon, menus, tabs).

```sh
open -na Ghostty.app --args \
  --config-default-files=false \
  --config-file=/path/to/bundled.ghostty \
  -e /path/to/my-tui
```

- `config-default-files` is CLI-only and exists precisely for this ("using
  Ghostty from the CLI in a way that minimizes external effects").
- The binary inside `Ghostty.app/Contents/MacOS` is a helper CLI and refuses
  to launch the GUI directly, so `open` is mandatory. `-n` forces a second
  process. `open` may swallow `-e`; escaping as `\-e` is a known workaround.
- Ghostty 1.3+ has AppleScript: `new window with configuration cfg` where
  `cfg` carries command, working directory, env and initial input. This is
  the cleanest way to get a window running your TUI inside an already-running
  Ghostty.

## Config knobs that matter for a single-TUI wrapper

The wrapper's [bundled configuration](../Resources/ghostty.conf) is the
authoritative example; see the [README](../README.md#configuration) for loading
and override behavior. The wrapper sets its command on the surface.

For other embedders, load a bundled config explicitly (routes 1-3), or pass
`--config-file` when launching Ghostty.app (route 4). A config-level command can
use `direct:/path/to/tui` to skip the shell, or `shell:` for shell expansion.

Things to remember:

- `env_vars`, `working_directory`, `initial_input` can be set per surface via
  the C struct instead of the config file.
- If you keep `TERM=xterm-ghostty`, bundle `zig-out/share/terminfo` and point
  `GHOSTTY_RESOURCES_DIR` at it (libghostty-spm and Trolley do this for you).
- App Sandbox must be off to fork a PTY child. Hardened runtime and
  notarization are fine.
- Bundle the TUI binary under `Contents/Resources` or `Contents/MacOS` and
  reference it by absolute path resolved at runtime; sign it as part of the
  bundle.
- Keybinds: Ghostty's defaults (Cmd+T new tab, Cmd+D split, etc.) reach the
  action callback; a single-surface app can simply ignore those actions or
  set `keybind = clear` in the config.

## Alternatives outside Ghostty

- SwiftTerm (`migueldeicaza/SwiftTerm`): pure Swift, AppKit view, stable
  API, used by several shipped SSH clients. Weaker rendering (reported
  Powerline/Nerd Font glyph issues), CPU text rendering. Reasonable fallback
  if libghostty churn becomes a problem.
- Electron/Tauri + xterm.js or `ghostty-web`: heavy, web stack.

## Sources

- Ghostty about / libghostty status: https://ghostty.org/docs/about
- libghostty C API docs (unofficial mirror of in-repo docs): https://ghostty-org-ghostty.mintlify.app/api/overview
- Config reference: https://ghostty.org/docs/config/reference
- AppleScript: https://ghostty.org/docs/features/applescript
- Mitchell Hashimoto, "Libghostty Is Coming": https://mitchellh.com/writing/libghostty-is-coming
- Swift Metal renderer announcement (July 2026): https://x.com/mitchellh/status/2072724957902381319
- libghostty-vt site: https://libghostty.tip.ghostty.org/
- ghostty-vt.xcframework on tip (PR #12149): https://github.com/ghostty-org/ghostty/pull/12149
- awesome-libghostty: https://github.com/Uzaaft/awesome-libghostty
- libghostty-spm: https://github.com/Lakr233/libghostty-spm
- Trolley: https://github.com/weedonandscott/trolley
- Ghostling (libghostty-vt + raylib reference): https://github.com/ghostty-org/ghostling
- macterm architecture notes: https://github.com/thdxg/macterm/blob/main/AGENTS.md
- justty: https://github.com/0x96f/justty
- Sessylph write-up: https://zenn.dev/saqoosha/articles/sessylph-libghostty-claude-code-terminal?locale=en
- Opening Ghostty with a command on macOS: https://github.com/ghostty-org/ghostty/discussions/7867 and https://github.com/ghostty-org/ghostty/discussions/4434
- SwiftTerm: https://github.com/migueldeicaza/SwiftTerm
