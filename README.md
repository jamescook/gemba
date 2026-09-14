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

Tryst, tryst-sdl and the tryst widget shards each live in their own
repo. gemba follows their `main` branches rather than their releases,
and `shard.lock` pins the exact commits it was last tested against - see
[Dependencies](#dependencies).

## Screenshots

![goodboy](assets/goodboy.png)

## Installing

### Homebrew (macOS)

```
brew install jamescook/tap/gemba
```

On Apple Silicon Macs running macOS 15 or later this installs a
prebuilt binary, with SDL3, Tcl/Tk and the rest as Homebrew
dependencies. Intel Macs build from source instead, including libmgba
and rcheevos, which also installs Crystal and CMake. The formula lives
in [jamescook/homebrew-tap](https://github.com/jamescook/homebrew-tap).

### From source

Needs a working host build first - see [Developing](#developing). Then:

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
(`/opt/homebrew`), so it collides with nothing brew owns. Under `sudo`,
pass `PREFIX` explicitly - `sudo make install` alone installs root-owned
files into your own `~/.local`.

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

The binary links Homebrew's dylibs by absolute path
(`/opt/homebrew/opt/{sdl3,sdl3_ttf,tcl-tk,...}`), so a copy built this
way and handed to someone else only runs if they have the same formulae
installed. Point them at the Homebrew install instead.

## Developing

Needs whatever tryst and tryst-sdl need (Crystal >= 1.21.0, Tcl/Tk 8.6
or 9, SDL3), plus libmgba and rcheevos - see tryst-sdl's own README for
per-platform SDL package names.

### Host build

A host build needs three vendored artifacts that git does not track and
nothing builds automatically - do this once before your first host
build. The Dockerfile and the Homebrew formula run the identical recipe,
so keep all three in sync if the versions or flags change.

```
# 1. libmgba, built minimal (no Qt/SDL frontend, no GL).
mkdir -p vendor
git clone --depth 1 --branch 0.10.5 https://github.com/mgba-emu/mgba.git vendor/mgba
cmake -S vendor/mgba -B vendor/build \
  -DMARKDOWN= \
  -DBUILD_SHARED=OFF -DBUILD_STATIC=ON \
  -DBUILD_QT=OFF -DBUILD_SDL=OFF \
  -DBUILD_GL=OFF -DBUILD_GLES2=OFF -DBUILD_GLES3=OFF \
  -DBUILD_LIBRETRO=OFF \
  -DUSE_SQLITE3=OFF -DUSE_ELF=OFF -DUSE_LZMA=OFF -DUSE_EDITLINE=OFF -DUSE_FFMPEG=OFF \
  -DUSE_LUA=OFF -DUSE_MINIZIP=OFF -DUSE_DISCORD_RPC=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCMAKE_INSTALL_PREFIX="$(pwd)/vendor/mgba-install" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build vendor/build -j "$(getconf _NPROCESSORS_ONLN)"
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

# 4. The Crystal dependencies, at the commits in shard.lock.
shards install
```

`vendor/` and `native/*.o` are both gitignored - this is a local build
step, not something to commit. Re-run it whenever `vendor/mgba-install`,
`vendor/rcheevos-build`, or `native/null_logger.o` go missing (e.g.
after a clean checkout).

### Tests

```
scripts/docker-test.sh                      # full suite, Debian forky
scripts/docker-test.sh spec/gemba_spec.cr   # one file
```

Run specs in Docker, not with `crystal spec` on the host: the suite
opens real Tk windows, which steal focus while it runs. Docker builds
libmgba and rcheevos itself, so it needs none of the host setup above.

### Dependencies

Every tryst-family dependency tracks `branch: main`, and
`shard.override.yml` forces tryst and tryst-vector to `main` everywhere
in the dependency graph. `shard.lock` is committed, so `shards install`,
the Docker image and the Homebrew formula all build the same commits. To
pick up new upstream commits, run `shards update`, run the full Docker
suite, and commit the updated lock.

## Releasing

1. Bump the version in `shard.yml`, `src/gemba.cr` and
   `spec/gemba_spec.cr`.
2. If the release should include newer tryst commits, `shards update`.
3. `scripts/docker-test.sh` - the full suite must pass.
4. Add a `CHANGELOG.md` entry dated today, commit, then tag and push:
   `git tag vX.Y.Z && git push origin main vX.Y.Z`.
5. Bump the Homebrew formula and publish its bottles - see
   [Maintaining](https://github.com/jamescook/homebrew-tap#maintaining)
   in jamescook/homebrew-tap. In short, open the bump pull request:

   ```
   brew bump-formula-pr --no-fork --no-browse \
     --url https://github.com/jamescook/gemba/archive/refs/tags/vX.Y.Z.tar.gz \
     jamescook/tap/gemba
   ```

   and once its checks pass, run the tap's publish workflow with that
   pull request's number instead of merging it.
