# Installing gemba

## Ruby

Ruby 3.2+ is required. Ruby 4.0 is recommended.

Install via [mise](https://mise.jdx.dev/), [rbenv](https://github.com/rbenv/rbenv), or your system package manager.

## Dependencies

gemba has three native dependencies that must be present at compile time:

| Dependency | What it provides |
|------------|-----------------|
| Tcl/Tk     | Windowing, menus, settings UI |
| SDL2       | Video rendering, audio, gamepad input |
| libmgba    | GBA emulation core |

### macOS (Homebrew)

```bash
brew install tcl-tk sdl2 sdl2_ttf sdl2_image sdl2_mixer sdl2_gfx cmake
```

libmgba isn't in Homebrew, so build it from source:

```bash
rake deps
```

This clones mGBA 0.10.5, builds a static library, and installs headers and libs to `/opt/homebrew`.

### Ubuntu / Debian

```bash
sudo apt install \
  tcl9.0-dev tk9.0-dev \
  libsdl2-dev libsdl2-ttf-dev libsdl2-image-dev libsdl2-mixer-dev libsdl2-gfx-dev \
  libmgba-dev
```

### Windows (MSYS2)

Using the UCRT64 environment:

```bash
pacman -S --needed \
  mingw-w64-ucrt-x86_64-tcl \
  mingw-w64-ucrt-x86_64-tk \
  mingw-w64-ucrt-x86_64-SDL2 \
  mingw-w64-ucrt-x86_64-SDL2_ttf \
  mingw-w64-ucrt-x86_64-SDL2_image \
  mingw-w64-ucrt-x86_64-SDL2_mixer \
  mingw-w64-ucrt-x86_64-SDL2_gfx \
  mingw-w64-ucrt-x86_64-mgba \
  mingw-w64-ucrt-x86_64-imagemagick
```

## Install

```bash
gem install gemba
```

### From source (development)

```bash
bundle install
rake compile
```

## Run

```bash
gemba [ROM_FILE]
```

If running from a source checkout, use `bin/gemba` instead.

## Tests

```bash
rake test                        # native (requires display or Xvfb)
rake docker:test                 # Docker (Linux, self-contained)
TCL_VERSION=8.6 rake docker:test # Docker with Tcl 8.6
```
