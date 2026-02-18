# Changelog — gemba

> **Beta**: gemba is functional but the API may change between minor versions.

All notable changes to gemba will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Game Boy and Game Boy Color ROM support (160×144 resolution, correct aspect ratio)
- Input recording and replay — record button inputs to `.gir` files and replay them deterministically
- Video/audio capture to `.grec` files (F10 hotkey)
- Input replay player with dedicated window (open via menu or Cmd/Ctrl+O)
- Open ROM hotkey (Ctrl+O / Cmd+O), context-sensitive when replay player is active
- Settings tabs for save states, recording, and hotkey customization
- Rewind support
- ROM Info window showing title, game code, publisher, platform, resolution
- Session logging
- CLI subcommands for decoding `.grec` and `.gir` files

### Changed

- `.grec` header FPS field now varies by platform (was always GBA; existing files decode fine)
- Clearer UI labels: video/audio capture ("Capture") vs input recording ("Record Inputs")
- Hotkeys for pause, screenshot, and open ROM now work without a ROM loaded

### Fixed

- Games no longer start paused on Linux/Windows when window doesn't have focus at startup

## [0.1.1] — 2026-02-17

### Changed

- Replace SDL2_gfx `fill_circle` with pure-Ruby scanline implementation using SDL2 `fill_rect`, removing the runtime dependency on SDL2_gfx
- Add `rake deps:sdl2` task to build SDL2 and satellite libs from source (for distros like Fedora 43+ that no longer package SDL2)
- Document Linux SDL2/SDL3 packaging situation in INSTALL.md

### Fixed

- ROM no longer starts paused on Linux/Windows when window doesn't have focus at startup

## [0.1.0] — 2026-02-16

### Added

- GBA emulation via libmgba with SDL2 video/audio rendering
- Keyboard and gamepad input with remappable controls and hotkeys
- Quick save/load and 10-slot save states with thumbnails
- Fast-forward (2x–4x or uncapped)
- Settings UI with video, audio, gamepad, and hotkey configuration
- GBA color correction and frame blending for authentic LCD appearance
- Per-game settings
- Locale support (English, Japanese)
- Pause on focus loss
- macOS, Linux, and Windows support

[0.1.1]: https://github.com/jamescook/gemba/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/jamescook/gemba/releases/tag/v0.1.0
