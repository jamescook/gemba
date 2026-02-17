# Development Setup

## Repository layout

gemba depends on two local gems during development: **teek** and **teek-sdl2**. The Gemfile auto-detects them as sibling directories:

```
~/open_source/
  teek/              # teek gem
    teek-sdl2/       # teek-sdl2 gem (nested inside teek)
  gemba/             # this repo
```

You can override the paths with `TEEK_PATH` and `TEEK_SDL2_PATH` environment variables if your layout differs.

## System dependencies

### macOS (Homebrew)

```bash
brew install tcl-tk sdl2 sdl2_ttf sdl2_image sdl2_mixer sdl2_gfx cmake
```

### Fedora / RHEL

```bash
sudo dnf install \
  tcl-devel tk-devel \
  SDL2-devel SDL2_ttf-devel SDL2_image-devel SDL2_mixer-devel SDL2_gfx-devel \
  cmake gcc gcc-c++ make git
```

### Ubuntu / Debian

```bash
sudo apt install \
  tcl-dev tk-dev \
  libsdl2-dev libsdl2-ttf-dev libsdl2-image-dev libsdl2-mixer-dev libsdl2-gfx-dev \
  cmake build-essential git
```

## Build steps

### 1. Compile teek-sdl2's C extension

The teek-sdl2 gem has a native extension that must be compiled inside its local checkout (bundler uses the path source, not a globally installed gem):

```bash
cd ~/open_source/teek/teek-sdl2
bundle install
rake compile
```

### 2. Build libmgba

On macOS and Fedora (no `libmgba-dev` package), build from source:

```bash
cd ~/open_source/gemba
rake deps
```

On Ubuntu/Debian you can skip this if you installed `libmgba-dev`.

### 3. Compile gemba's C extension

```bash
cd ~/open_source/gemba
bundle install
rake compile
```

## Running tests

```bash
rake test                        # native (requires display or Xvfb)
rake docker:test                 # Docker (Linux, self-contained)
TCL_VERSION=8.6 rake docker:test # Docker with Tcl 8.6
```

## Docker

Docker builds handle all dependencies automatically. Use `LOCAL_DEPS=1` to include your local teek/teek-sdl2 changes:

```bash
LOCAL_DEPS=1 rake docker:test
```
