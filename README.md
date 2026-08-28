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
container builds both from source (`vendor/build_rcheevos.sh` is the
same rcheevos recipe, runnable directly on host once
`vendor/rcheevos` is cloned and checked out to the pinned commit), or
tryst-sdl's own README for per-platform SDL package names.
