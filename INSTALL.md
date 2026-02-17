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

### Linux SDL2 availability

gemba requires SDL2. Unfortunately SDL2 packaging varies across Linux distros:

- **Ubuntu / Debian** — SDL2 packages are available and work out of the box. SDL3 is not yet packaged.
- **Fedora** — Recent versions have replaced SDL2 with SDL3. Fedora ships SDL2 compatibility shims, but these crash the gem at runtime. Build SDL2 from source with `rake deps:sdl2` (see below).

Migrating gemba to SDL3 is not currently feasible for two reasons: the packaging situation is reversed (distros that have SDL3 packages don't have SDL2, and vice versa), and SDL3_mixer is still in RC with no official release yet. There is no single SDL version that works everywhere today.

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
  tcl-dev tk-dev \
  libsdl2-dev libsdl2-ttf-dev libsdl2-image-dev libsdl2-mixer-dev libsdl2-gfx-dev \
  libmgba-dev
```

If the system SDL2 packages give you trouble, you can build SDL2 from source using the gemba source checkout:

```bash
sudo apt install cmake build-essential git pkg-config
git clone https://github.com/jamescook/gemba.git
cd gemba
rake deps:sdl2
```

This builds SDL2, SDL2_ttf, SDL2_image, and SDL2_mixer from source and installs them to `/usr/local`.

### Fedora / RHEL

> **Fedora 43+:** The SDL2 packages below have been replaced by SDL3. The SDL2 compatibility shims shipped by Fedora do not work with gemba (they crash at runtime). Build SDL2 from source instead:
>
> ```bash
> rake deps:sdl2
> ```
>
> This clones and builds SDL2, SDL2_ttf, SDL2_image, and SDL2_mixer from source and installs them to `/usr/local` (override with `SDL2_PREFIX`). Requires cmake, gcc, make, and pkg-config.

For Fedora 42 and earlier:

```bash
sudo dnf install \
  tcl-devel tk-devel \
  SDL2-devel SDL2_ttf-devel SDL2_image-devel SDL2_mixer-devel SDL2_gfx-devel \
  cmake gcc gcc-c++ make git
```

libmgba isn't packaged in Fedora, so build it from source:

```bash
rake deps
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
