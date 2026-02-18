# gemba

A GBA emulator frontend powered by [teek](https://github.com/jamescook/teek) and [libmgba](https://github.com/mgba-emu/mgba).

A full-featured GBA player with video/audio rendering, keyboard and gamepad
input, save states, and a settings UI.

## Installation

See [INSTALL.md](INSTALL.md) for platform-specific dependency setup.

## Usage

```
gemba [command] [options]
```

### Commands

| Command | Description |
|---------|-------------|
| `play` | Play a ROM (default if omitted) |
| `record` | Record video+audio to .grec (headless) |
| `decode` | Encode .grec to video via ffmpeg |
| `replay` | Replay a .gir input recording |
| `config` | Show or reset configuration |
| `version` | Show version |

Run `gemba <command> --help` for command-specific options.

### Examples

```sh
# Play a ROM (these are equivalent)
gemba game.gba
gemba play game.gba

# Play with options
gemba play --scale 2 --fullscreen game.gba

# Record 10 seconds of gameplay (headless)
gemba record --frames 600 game.gba

# Show recording stats
gemba decode --stats recording.grec

# Encode to video
gemba decode -o clip.mp4 recording.grec

# Replay an input recording
gemba replay session.gir

# Reset config
gemba config --reset
```

## Features

- GBA emulation via libmgba
- SDL2 video rendering with configurable window scale (1x-4x)
- Integer scaling and nearest-neighbor/bilinear pixel filtering
- GBA color correction (Pokefan531 formula) for authentic LCD appearance
- Fullscreen support
- SDL2 audio with volume control and mute
- Keyboard and gamepad input with remappable controls and hotkeys
- Quick save/load and 10-slot save state picker with thumbnails
- Turbo/fast-forward mode
- ROM info viewer
- Persistent user configuration with settings UI

## Language Support

The UI supports multiple languages via YAML-based locale files. The active
language is auto-detected from the system environment (`LANG`) or can be
set manually in the config.

Currently supported:

| Language | Code |
|----------|------|
| English  | `en` |
| Japanese | `ja` |

To force a specific language:

```ruby
Gemba.user_config.locale = 'ja'
```

Adding a new language: create `lib/gemba/locales/<code>.yml` following
the structure in `en.yml`.

## Future Ideas

- Game picker / ROM browser
- GB/GBC support
- ROM patching (IPS/UPS)
- Local multiplayer (link cable emulation)
- RetroAchievements integration
- Solar sensor and tilt/gyro cartridge emulation
- Audio visualizer / channel debug view
- Ruby scripting API

## Supported Platforms

| Platform | Notes |
|----------|-------|
| macOS (Apple Silicon) | Primary development platform |
| Linux (x86_64) | Tested in CI via Docker (Ubuntu 24.04) |
| Windows 10+ | Tested in CI (GitHub Actions) and manually in VM |

## License

MIT. See [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES) for bundled font licenses.
