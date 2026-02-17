# Changelog — gemba

> **Beta**: gemba is functional but the API may change between minor versions.

All notable changes to gemba will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.1] — 2026-02-17

### Changed

- Replace SDL2_gfx `fill_circle` with pure-Ruby scanline implementation using SDL2 `fill_rect`, removing the runtime dependency on SDL2_gfx
- Add `rake deps:sdl2` task to build SDL2 and satellite libs from source (for distros like Fedora 43+ that no longer package SDL2)
- Document Linux SDL2/SDL3 packaging situation in INSTALL.md

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
