#!/bin/bash
#
# Copyright (c) 2018 The Chromium Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This script has been modified for use in Android. It is used to generate .bp
# files and files in the config/ directories needed to build libaom.
#
# Every time the upstream source code is updated this script must be run.
#
# Usage:
# $ ./generate_config.sh
# Requirements:
# Install the following Debian packages.
# - cmake3
# - yasm or nasm
# Toolchain for armv7:
# - gcc-arm-linux-gnueabihf
# - g++-arm-linux-gnueabihf
# Toolchain for arm64:
# - gcc-aarch64-linux-gnu
# - g++-aarch64-linux-gnu
# 32bit build environment for cmake. Including but potentially not limited to:
# - lib32gcc-7-dev
# - lib32stdc++-7-dev
# Alternatively: treat 32bit builds like Windows and manually tweak aom_config.h

set -eE

# sort() consistently.
export LC_ALL=C

BASE=$(pwd)
SRC="${BASE}/libaom"
CFG="${BASE}/config"
TMP=$(mktemp -d "${BASE}/build.XXXX")

# Clean up and prepare config directory
rm -rf "${CFG}"
mkdir -p "${CFG}/config"

function clean {
  rm -rf "${TMP}"
}

# Create empty temp and config directories.
# $1 - Header file directory.
function reset_dirs {
  cd "${BASE}"
  rm -rf "${TMP}"
  mkdir "${TMP}"
  cd "${TMP}"

  echo "Generate ${1} config files."
  mkdir -p "${CFG}/${1}/config"
}

if [ $# -ne 0 ]; then
  echo "Unknown option(s): ${@}"
  exit 1
fi

# Missing function:
# find_duplicates
# We may have enough targets to avoid re-implementing this.

# Generate Config files.
# $1 - Header file directory.
# $2 - cmake options.
function gen_config_files {
  cmake "${SRC}" ${2} &> cmake.txt

  case "${1}" in
    x86*)
      egrep "#define [A-Z0-9_]+ [01]" config/aom_config.h | \
        awk '{print "%define " $2 " " $3}' > config/aom_config.asm
      ;;
  esac

  cp config/aom_config.{h,c,asm} "${CFG}/${1}/config/"

  cp config/*_rtcd.h "${CFG}/${1}/config/"
  #clang-format -i "${CFG}/${1}/config/"*_rtcd.h
}

function update_readme {
  local IFS=$'\n'
  # Split git log output '<date>\n<commit hash>' on the newline to produce 2
  # array entries.
  local vals=($(git -C "${SRC}" --no-pager log -1 --format="%cd%n%H" \
    --date=format:"%A %B %d %Y"))
  sed -E -i.bak \
    -e "s/^(Date:)[[:space:]]+.*$/\1 ${vals[0]}/" \
    -e "s/^(Commit:)[[:space:]]+[a-f0-9]{40}/\1 ${vals[1]}/" \
    ${BASE}/README.android
  rm ${BASE}/README.android.bak
  cat <<EOF

README.android updated with:
Date: ${vals[0]}
Commit: ${vals[1]}
EOF
}

cd "${TMP}"

# Scope 'trap' error reporting to configuration generation.
(
trap '{
  [ -f ${TMP}/cmake.txt ] && cat ${TMP}/cmake.txt
  echo "Build directory ${TMP} not removed automatically."
}' ERR

all_platforms="-DCONFIG_SIZE_LIMIT=1"
all_platforms+=" -DDECODE_HEIGHT_LIMIT=16384 -DDECODE_WIDTH_LIMIT=16384"
all_platforms+=" -DCONFIG_AV1_ENCODER=0"
all_platforms+=" -DCONFIG_LOWBITDEPTH=1"
all_platforms+=" -DCONFIG_MAX_DECODE_PROFILE=0"
all_platforms+=" -DCONFIG_NORMAL_TILE_MODE=1"
# Android requires ssse3. Simplify the build by disabling everything above that
# and RTCD.
all_platforms+=" -DENABLE_SSE4_1=0"
all_platforms+=" -DCONFIG_RUNTIME_CPU_DETECT=0"

toolchain="-DCMAKE_TOOLCHAIN_FILE=${SRC}/build/cmake/toolchains"

reset_dirs x86
gen_config_files x86 "${toolchain}/x86-linux.cmake ${all_platforms} -DCONFIG_PIC=1"

# libaom_srcs.gni and aom_version.h are shared.
cp libaom_srcs.gni "${BASE}"
cp config/aom_version.h "${CFG}/config/"

reset_dirs x86_64
gen_config_files x86_64 "${all_platforms}"

reset_dirs arm
gen_config_files arm "${toolchain}/armv7-linux-gcc.cmake ${all_platforms}"

reset_dirs arm64
gen_config_files arm64 "${toolchain}/arm64-linux-gcc.cmake ${all_platforms}"
)

# This needs to be run by update_libaom.sh before the .git file is removed.
#update_readme

# libaom_srcs.gni was built for Chromium. Remove:
# - the path prefix (//third_party/libaom/source/)
# - comments (lines starting with #)
# - header files
# - perl scripts (rtcd)

rm -f "${BASE}/Android.bp"
(
  echo "// THIS FILE IS AUTOGENERATED, DO NOT EDIT"
  echo "// Generated from Android.bp.in, run ./generate_config.sh to regenerate"
  echo
  cat "${BASE}/libaom_srcs.gni" |
    grep -v ^\# |
    sed 's/\/\/third_party\/libaom\/source\///' |
    grep -v h\",$ |
    grep -v pl\",$
  cat "${BASE}/Android.bp.in"
) > "${BASE}/Android.bp"

rm -f "${BASE}/libaom_srcs.gni"
bpfmt -w "${BASE}/Android.bp" || echo "bpfmt not found: format Android.bp manually."


clean
