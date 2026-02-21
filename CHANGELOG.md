# Changelog — gemba

> **Beta**: gemba is functional but the API may change between minor versions.

All notable changes to gemba will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- RetroAchievements integration — earn achievements while you play; progress tracked and submitted in real time
- Rich Presence support — reports current game activity to your RetroAchievements profile
- Achievements window showing earned/unearned status, points, and descriptions for the current game
- `gemba ra` CLI commands: `login`, `verify`, `logout`, and `achievements` (list a ROM's achievements without launching the emulator)
- Loading a save state while paused now renders the frame the state was captured at, so you can see exactly where you are before resuming
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
- ROM Patcher — apply IPS, BPS, and UPS patch files via GUI (View > Patch ROM…) or CLI (`gemba patch`)
- ZIP ROM support in patcher — drag in a zipped ROM and the output is a plain `.gba`
- Mouse cursor auto-hides after 2 seconds of inactivity while a game is playing; restores on movement or pause
- `?` hotkey toggles a floating hotkey reference panel beside the emulator window; emulation auto-pauses while it is open
- Help window auto-pauses emulation while open
- BIOS loading — configure a GBA BIOS file via Settings > System; gemba validates the file size (16 384 bytes), identifies Official GBA BIOS and NDS GBA Mode BIOS by checksum, and copies it to the gemba data directory; "Skip BIOS intro" option available for supported files

### Changed

- `.grec` header FPS field now varies by platform (was always GBA; existing files decode fine)
- Clearer UI labels: video/audio capture ("Capture") vs input recording ("Record Inputs")
- Hotkeys for pause, screenshot, and open ROM now work without a ROM loaded

### Fixed

- Games no longer start paused on Linux/Windows when window doesn't have focus at startup
- Opening the Logs Directory menu item no longer crashes (platform_open was not loaded by Zeitwerk)

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
