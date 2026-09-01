# Dev/test image for gemba. Mirrors tryst-sdl/Dockerfile for the SDL3
# packages (this shard depends on tryst-sdl), plus builds libmgba from
# source with the same minimal flags gemba's own Rakefile uses (see
# README.md) - the same recipe run by hand on host for
# vendor/mgba-install, reproduced here so Docker verification is
# real, not stubbed past.
#
# Built from this repo's own root as context. tryst, tryst-sdl, and the
# settings UI's tryst-switch/tryst-segmented/tryst-value-slider are all
# `github:` shard dependencies (their own repos), fetched directly by
# `shards install` rather than needing to be copied into the context.
#
# Must be run as `docker run --rm --init <image>` - same requirement as
# every other Dockerfile in this repo. Without --init, xvfb-run hangs
# forever as PID 1.
FROM debian:forky

ARG CRYSTAL_VERSION=1.21.0
ARG CRYSTAL_RELEASE=1

# The --mount=type=cache below lets .github/workflows' CI build persist
# apt's downloaded packages across runs (via buildkit-cache-dance, see
# that workflow's own comment) instead of re-fetching this whole list -
# bigger here than crystal-teek's own Dockerfile, so it matters more.
# No effect on a plain `docker build`/scripts/docker-test.sh run on
# host: BuildKit is Docker Desktop's default builder there too, so the
# cache mount is honored locally as well, just without anything
# restoring/saving it across separate `docker build` invocations. A
# cache mount isn't part of the resulting image layer either way, so
# there's no `rm -rf /var/lib/apt/lists/*` cleanup needed afterward.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    tcl-dev tk-dev \
    libsdl3-dev libsdl3-mixer-dev libsdl3-image-dev libsdl3-ttf-dev \
    libthorvg-dev \
    xvfb xauth \
    cmake make git \
    libpng-dev libzip-dev zlib1g-dev \
    ffmpeg \
    ca-certificates curl gcc g++ pkg-config \
    libpcre2-dev libgc-dev libevent-dev libssl-dev libyaml-dev libxml2-dev

RUN set -eux; \
    arch="$(uname -m)"; \
    curl -fsSL -o /tmp/crystal.tar.gz \
      "https://github.com/crystal-lang/crystal/releases/download/${CRYSTAL_VERSION}/crystal-${CRYSTAL_VERSION}-${CRYSTAL_RELEASE}-linux-${arch}.tar.gz"; \
    mkdir -p /opt/crystal; \
    tar -xzf /tmp/crystal.tar.gz -C /opt/crystal --strip-components=1; \
    rm /tmp/crystal.tar.gz; \
    ln -s /opt/crystal/bin/crystal /usr/local/bin/crystal; \
    ln -s /opt/crystal/bin/shards /usr/local/bin/shards; \
    crystal --version

WORKDIR /app

# libmgba, built from source with the exact minimal flags gemba's own
# Rakefile uses (BUILD_QT/SDL/GL*/LIBRETRO off, USE_SQLITE3/ELF/LZMA/
# EDITLINE off) plus USE_FFMPEG=OFF - not in gemba's own list, but
# needed here too: without it, e-Reader card support (compiled in
# unconditionally when ffmpeg dev headers are merely present, unrelated
# to whether USE_FFMPEG is requested) links against libswscale, which
# this minimal build deliberately has no other use for. Confirmed
# directly on host - see lib_mgba.cr's own comment.
#
# Deliberately BEFORE copying gemba's own source below: this step
# depends on nothing from this shard (only the pinned mgba tag), so
# Docker's layer cache reuses this ~2-3 minute compile across every
# rebuild that only changes gemba's Crystal code - copying src/ first
# would invalidate this layer (and force a full libmgba recompile) on
# every single source edit instead.
RUN set -eux; \
    mkdir -p vendor; \
    git clone --depth 1 --branch 0.10.5 https://github.com/mgba-emu/mgba.git vendor/mgba; \
    cmake -S vendor/mgba -B vendor/build \
      -DMARKDOWN= \
      -DBUILD_SHARED=OFF -DBUILD_STATIC=ON \
      -DBUILD_QT=OFF -DBUILD_SDL=OFF \
      -DBUILD_GL=OFF -DBUILD_GLES2=OFF -DBUILD_GLES3=OFF \
      -DBUILD_LIBRETRO=OFF -DSKIP_FRONTEND=ON \
      -DUSE_SQLITE3=OFF -DUSE_ELF=OFF -DUSE_LZMA=OFF -DUSE_EDITLINE=OFF -DUSE_FFMPEG=OFF \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
      -DCMAKE_INSTALL_PREFIX=/app/vendor/mgba-install \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5; \
    cmake --build vendor/build -j "$(nproc)"; \
    cmake --install vendor/build; \
    rm -rf vendor/mgba vendor/build

# rcheevos (RetroAchievements' condition-evaluation engine) - pinned to
# the same commit ruby gemba's own vendor/rcheevos submodule uses.
# Built as a plain static lib (no cmake, no Ruby/ext glue needed - see
# lib_rcheevos.cr's own comment on why rc_runtime_t needs no Crystal
# struct layout at all), same before-COPY-src placement as libmgba
# above so this rarely-changing dependency doesn't get rebuilt on every
# gemba source edit.
RUN set -eux; \
    mkdir -p vendor/rcheevos-build; \
    git clone --quiet https://github.com/RetroAchievements/rcheevos.git vendor/rcheevos; \
    git -C vendor/rcheevos checkout --quiet e9ca3694c862b61235595176dac4b22677848c93; \
    cd vendor/rcheevos-build; \
    for f in ../rcheevos/src/rcheevos/alloc.c ../rcheevos/src/rcheevos/condition.c \
             ../rcheevos/src/rcheevos/condset.c ../rcheevos/src/rcheevos/format.c \
             ../rcheevos/src/rcheevos/lboard.c ../rcheevos/src/rcheevos/memref.c \
             ../rcheevos/src/rcheevos/operand.c ../rcheevos/src/rcheevos/richpresence.c \
             ../rcheevos/src/rcheevos/runtime.c ../rcheevos/src/rcheevos/runtime_progress.c \
             ../rcheevos/src/rcheevos/trigger.c ../rcheevos/src/rcheevos/value.c \
             ../rcheevos/src/rc_compat.c ../rcheevos/src/rc_util.c ../rcheevos/src/rhash/md5.c; do \
      cc -c -O2 -I ../rcheevos/include -I ../rcheevos/src "$f" -o "$(basename "$f" .c).o"; \
    done; \
    ar rcs librcheevos.a *.o; \
    cd ../..; \
    rm -rf vendor/rcheevos

# shard.override.yml must ride along with shard.yml: it is what forces
# tryst/tryst-vector to branch HEAD past the released shards' own ~> 0.1
# constraints (see its own comment) - without it, `shards install` below
# fails to resolve at all.
COPY shard.yml shard.override.yml ./
COPY native/ native/

# native/null_logger.c can't be built until libmgba's own headers exist
# (just installed above) - see its own header comment for why this one
# function has to be real C, not Crystal `lib` FFI (a genuine va_list
# parameter, which Crystal cannot express).
RUN cc -c -I vendor/mgba-install/include native/null_logger.c -o native/null_logger.o

# High-churn layers last - only these get invalidated on an ordinary
# source edit, not the expensive libmgba build above.
COPY src/ src/
COPY spec/ spec/
COPY assets/ assets/

# shards install resolves tryst/tryst-sdl/tryst-vector/etc. via their
# `github:` branch refs in shard.yml - Docker's cache key for this layer
# is shard.yml's own content, which never changes just because an
# upstream dependency got a new commit. On a one-shot build (GitHub's
# old hosted runners) that was invisible; on this machine's persistent
# self-hosted Docker daemon it meant every build silently kept
# resolving whatever commit was fetched the FIRST time this layer ever
# ran, no matter how many times the actual dependency repos changed
# afterward (confirmed directly: stuck testing an hours-stale tryst
# commit through several rounds of pushed fixes). CACHEBUST forces this
# layer (and only this one - everything above it still caches normally)
# to always re-resolve.
ARG CACHEBUST=1
RUN shards install

# Sorted file list rather than bare `crystal spec`: the runner's own
# glob returns files in readdir order, which reshuffles whenever a spec
# file is added - and with it which example inherits which neighbor's
# leftover state, turning any cross-spec leak into a moving target
# (bit for real: a leaked worker thread's allocations landed in an
# allocation-counting spec only under one particular ordering). Sorted
# order keeps a failure reproducible run over run.
CMD xvfb-run -a sh -c 'crystal spec $(find spec -name "*_spec.cr" | sort)'
