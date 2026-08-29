#!/bin/sh
# Builds the gemba Docker test image and runs its spec suite (see
# ../Dockerfile), then cleans up the dangling images repeated builds
# leave behind. Labeled so cleanup only ever touches this image.
#
# The build context is this repo's own root: tryst, tryst-sdl, and the
# rest are `github:` shard dependencies, fetched by `shards install`
# inside the image rather than needing to be copied in. Run it from
# anywhere.
#
# Any arguments are passed straight through to `crystal spec` inside the
# container, so a focused run works here as well as on the host:
#
#   scripts/docker-test.sh                    # everything
#   scripts/docker-test.sh spec/gemba_spec.cr  # one file
set -eu

IMAGE=gemba-test
LABEL=project=gemba

# This script lives in <repo>/scripts, so the root is one up.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

docker build --build-arg CACHEBUST="$(date +%s)" --label "$LABEL" -t "$IMAGE" -f "$ROOT/Dockerfile" "$ROOT"

status=0
if [ "$#" -eq 0 ]; then
  docker run --rm --init "$IMAGE" || status=$?
else
  docker run --rm --init "$IMAGE" xvfb-run -a crystal spec "$@" || status=$?
fi

docker image prune -f --filter "label=$LABEL" >/dev/null

exit "$status"
