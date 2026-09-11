# gemba

A Crystal/Tryst port of gemba, a GBA emulator frontend (ruby original:
`teek` + libmgba).

Its main job is to be a real, non-trivial application built on Tryst -
the kind of thing that finds the rough edges a widget-by-widget test
suite never will: real concurrency (a full emulation loop running
alongside Tk's own event loop), real file I/O, a real native CDN fetch,
a settings UI, modals, hotkeys, all of it. Every gap it exposes in Tryst
gets fixed in Tryst, not worked around here. A working, genuinely
playable GBA frontend is very much the goal too - just the second one.

It lives inside this monorepo so a change to Tryst/tryst-sdl that gemba
needed can land in the same commit as the code that needed it, rather
than across two repos with a version bump in between.

## Screenshots

![goodboy](assets/goodboy.png)

## Building

```
shards install
crystal spec                    # host
scripts/docker-test.sh          # Debian forky, same suite
```

Needs whatever tryst and tryst-sdl need (Crystal >= 1.21.0, Tcl/Tk 8.6,
SDL3), plus libmgba and rcheevos - see the Dockerfile for how the
container builds both from source, or tryst-sdl's own README for
per-platform SDL package names.

## Installing

```
make                      # release build -> bin/release/gemba
make install              # -> ~/.local/bin/gemba + ~/.local/share/gemba
make && sudo make install PREFIX=/usr/local   # system-wide
make DESTDIR=/tmp/stage install       # staged, for a formula or .deb
make uninstall
```

`make install` only rebuilds when a source file is newer than the
release binary, so the `sudo` half of the system-wide line just copies -
no second release build running as root. The release build lands in
`bin/release/`, not `bin/`, so a debug `shards build` never gets
installed by mistake.

`PREFIX` defaults to `~/.local` - no sudo, and it is the XDG/systemd
user convention most modern Linux distros put on `PATH` when it exists
(Debian/Ubuntu's stock `~/.profile` does). macOS does not, so `make
install` prints a hint if the target bin dir is missing from `PATH`.
`/usr/local` is the system-wide choice on both: it is in `/etc/paths` on
every Mac, and on Apple Silicon it is not Homebrew's prefix
(`/opt/homebrew`), so it collides with nothing brew owns.

The install writes two things, and both are needed:

```
$PREFIX/bin/gemba
$PREFIX/share/gemba/{assets,data,locales}
```

The binary finds that second half through `../share/gemba` relative to
itself, so the pair relocates anywhere as a unit without the prefix
being compiled in. `gemba config` prints which one it resolved:

```
Data: /usr/local/share/gemba (installed)
Data: /path/to/checkout (source tree)
```

A build run straight out of a checkout (`crystal run`, or `shards build`
with no `make install`) has no `share/` beside its binary and reads the
source tree instead - which is why the second line exists and why a
checkout needs no install to be developed in.

Note that the binary links Homebrew's dylibs by absolute path
(`/opt/homebrew/opt/{sdl3,sdl3_ttf,tcl-tk,...}`), so a copy handed to
someone else only runs if they have the same formulae installed. A tap
formula declaring those as `depends_on` is the fix, and is not written
yet.

## Developing (host build)

`crystal run`/`crystal spec` on host need three vendored artifacts that
git does not track and nothing builds automatically - do this once
before your first host build (the Dockerfile runs the identical recipe
for the container image):

```
# 1. libmgba, built minimal (no Qt/SDL frontend, no GL) - same flags
#    the Dockerfile uses, so keep them in sync if either changes.
mkdir -p vendor
git clone --depth 1 --branch 0.10.5 https://github.com/mgba-emu/mgba.git vendor/mgba
cmake -S vendor/mgba -B vendor/build \
  -DMARKDOWN= \
  -DBUILD_SHARED=OFF -DBUILD_STATIC=ON \
  -DBUILD_QT=OFF -DBUILD_SDL=OFF \
  -DBUILD_GL=OFF -DBUILD_GLES2=OFF -DBUILD_GLES3=OFF \
  -DBUILD_LIBRETRO=OFF -DSKIP_FRONTEND=ON \
  -DUSE_SQLITE3=OFF -DUSE_ELF=OFF -DUSE_LZMA=OFF -DUSE_EDITLINE=OFF -DUSE_FFMPEG=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCMAKE_INSTALL_PREFIX="$(pwd)/vendor/mgba-install" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build vendor/build -j "$(nproc)"
cmake --install vendor/build
rm -rf vendor/mgba vendor/build

# 2. rcheevos, pinned to the commit ruby gemba's own vendor/rcheevos
#    submodule uses.
git clone --quiet https://github.com/RetroAchievements/rcheevos.git vendor/rcheevos
git -C vendor/rcheevos checkout --quiet e9ca3694c862b61235595176dac4b22677848c93
scripts/build_rcheevos.sh
rm -rf vendor/rcheevos

# 3. native/null_logger.o - real C (a genuine va_list parameter Crystal
#    can't express), built against libmgba's just-installed headers.
cc -c -I vendor/mgba-install/include native/null_logger.c -o native/null_logger.o
```

`vendor/` and `native/*.o` are both gitignored - this is a local build
step, not something to commit. Re-run it whenever `vendor/mgba-install`,
`vendor/rcheevos-build`, or `native/null_logger.o` go missing (e.g.
after a clean checkout).
