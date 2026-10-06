#!/usr/bin/env bash
# Builds mp_diag.gba with the devkitpro/devkitarm Docker image.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
docker run --rm -v "$DIR:/work" -w /work devkitpro/devkitarm:latest bash -c '
  set -e
  export DEVKITPRO=/opt/devkitpro DEVKITARM=/opt/devkitpro/devkitARM
  PATH=$DEVKITARM/bin:$DEVKITPRO/tools/bin:$PATH
  arm-none-eabi-gcc -mthumb -mthumb-interwork -O2 -Wall -specs=gba.specs \
    -I$DEVKITPRO/libgba/include main.c -L$DEVKITPRO/libgba/lib -lgba -o mp_diag.elf
  arm-none-eabi-objcopy -O binary mp_diag.elf mp_diag.gba
  gbafix -tMPDIAG mp_diag.gba
  rm -f mp_diag.elf'
ls -l "$DIR/mp_diag.gba"
