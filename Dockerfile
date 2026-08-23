# Dev/test image for gemba. Mirrors tryst-sdl/Dockerfile for the SDL3
# packages (this shard depends on tryst-sdl), plus builds libmgba from
# source with the same minimal flags gemba's own Rakefile uses (see
# gemba/README.md) - the same recipe run by hand on host for
# gemba/vendor/mgba-install, reproduced here so Docker verification is
# real, not stubbed past.
#
# Built from the REPO ROOT as context, not from this directory - gemba
# depends on tryst (path: ../), tryst-sdl (path: ../tryst-sdl), and the
# settings UI's tryst-switch/tryst-segmented/tryst-value-slider plus
# their own shared tryst-vector dependency, so all of those have to be
# inside the build context too.
#
# Must be run as `docker run --rm --init <image>` - same requirement as
# every other Dockerfile in this repo. Without --init, xvfb-run hangs
# forever as PID 1.
FROM debian:forky

ARG CRYSTAL_VERSION=1.21.0
ARG CRYSTAL_RELEASE=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    tcl-dev tk-dev \
    libsdl3-dev libsdl3-mixer-dev libsdl3-image-dev libsdl3-ttf-dev \
    libthorvg-dev \
    xvfb xauth \
    cmake make git \
    libpng-dev libzip-dev zlib1g-dev \
    ca-certificates curl gcc g++ pkg-config \
    libpcre2-dev libgc-dev libevent-dev libssl-dev libyaml-dev libxml2-dev \
    && rm -rf /var/lib/apt/lists/*

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

# Both path-dependency shards, laid out exactly as they are in the repo
# so `path:` resolves the same way it does on a developer's machine.
WORKDIR /app
COPY shard.yml ./
COPY src/ src/

WORKDIR /app/tryst-sdl
COPY tryst-sdl/shard.yml ./
COPY tryst-sdl/src/ src/

WORKDIR /app/tryst-vector
COPY tryst-vector/shard.yml ./
COPY tryst-vector/src/ src/

WORKDIR /app/tryst-switch
COPY tryst-switch/shard.yml ./
COPY tryst-switch/src/ src/

WORKDIR /app/tryst-segmented
COPY tryst-segmented/shard.yml ./
COPY tryst-segmented/src/ src/

WORKDIR /app/tryst-value-slider
COPY tryst-value-slider/shard.yml ./
COPY tryst-value-slider/src/ src/

WORKDIR /app/gemba

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
      -DCMAKE_INSTALL_PREFIX=/app/gemba/vendor/mgba-install \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5; \
    cmake --build vendor/build -j "$(nproc)"; \
    cmake --install vendor/build; \
    rm -rf vendor/mgba vendor/build

COPY gemba/shard.yml ./
COPY gemba/native/ native/

# native/null_logger.c can't be built until libmgba's own headers exist
# (just installed above) - see its own header comment for why this one
# function has to be real C, not Crystal `lib` FFI (a genuine va_list
# parameter, which Crystal cannot express).
RUN cc -c -I vendor/mgba-install/include native/null_logger.c -o native/null_logger.o

# High-churn layers last - only these get invalidated on an ordinary
# source edit, not the expensive libmgba build above.
COPY gemba/src/ src/
COPY gemba/spec/ spec/
COPY gemba/assets/ assets/

RUN shards install

CMD ["xvfb-run", "-a", "crystal", "spec"]
