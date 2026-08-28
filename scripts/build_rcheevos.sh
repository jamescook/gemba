#!/bin/sh
# Builds vendor/rcheevos-build/librcheevos.a from a vendor/rcheevos
# checkout - run this after cloning vendor/rcheevos and checking out
# the pinned commit (see Dockerfile for the exact commit and the same
# recipe run in the container).
set -eu
cd "$(dirname "$0")/../vendor"
mkdir -p rcheevos-build
cd rcheevos-build

SRCS="
../rcheevos/src/rcheevos/alloc.c
../rcheevos/src/rcheevos/condition.c
../rcheevos/src/rcheevos/condset.c
../rcheevos/src/rcheevos/format.c
../rcheevos/src/rcheevos/lboard.c
../rcheevos/src/rcheevos/memref.c
../rcheevos/src/rcheevos/operand.c
../rcheevos/src/rcheevos/richpresence.c
../rcheevos/src/rcheevos/runtime.c
../rcheevos/src/rcheevos/runtime_progress.c
../rcheevos/src/rcheevos/trigger.c
../rcheevos/src/rcheevos/value.c
../rcheevos/src/rc_compat.c
../rcheevos/src/rc_util.c
../rcheevos/src/rhash/md5.c
"

for f in $SRCS; do
  cc -c -O2 -I ../rcheevos/include -I ../rcheevos/src "$f" -o "$(basename "$f" .c).o"
done

ar rcs librcheevos.a *.o
echo "built $(pwd)/librcheevos.a"
