#!/usr/bin/env bash
set -euo pipefail
TASK_DATA_DIR="${1:-$PWD/.zig-cache/parity-data}"
mkdir -p "$TASK_DATA_DIR"
if [[ ! -f "$TASK_DATA_DIR/icu/usr/local/include/unicode/uvernum.h" ]]; then
  curl --fail --location --retry 3 https://github.com/unicode-org/icu/releases/download/release-78.3/icu4c-78.3-Ubuntu22.04-x64.tgz --output "$TASK_DATA_DIR/icu.tgz"
  echo "2f33e1c2913de1248f7c51e8cd94898acf6317e87ea1c71b3546ec116e419e5ad08af4045e6ebf24a129aff2ea48549277dc0da8944951a3e6579177e04fa2a3  $TASK_DATA_DIR/icu.tgz" | sha512sum --check
  tar -xzf "$TASK_DATA_DIR/icu.tgz" -C "$TASK_DATA_DIR"
fi
if [[ ! -f "$TASK_DATA_DIR/zoneinfo/.version" ]]; then
  curl --fail --location --retry 3 https://data.iana.org/time-zones/releases/tzdata2026b.tar.gz --output "$TASK_DATA_DIR/tzdata.tar.gz"
  echo "114543d9f19a6bfeb5bca43686aea173d38755a3db1f2eec112647ae92c6f544  $TASK_DATA_DIR/tzdata.tar.gz" | sha256sum --check
  mkdir -p "$TASK_DATA_DIR/tzdata" "$TASK_DATA_DIR/zoneinfo"
  tar -xzf "$TASK_DATA_DIR/tzdata.tar.gz" -C "$TASK_DATA_DIR/tzdata"
  TASK_SOURCES=()
  for name in africa antarctica asia australasia europe northamerica southamerica backward etcetera; do
    TASK_SOURCES+=("$TASK_DATA_DIR/tzdata/$name")
  done
  zic -d "$TASK_DATA_DIR/zoneinfo" "${TASK_SOURCES[@]}"
  cp "$TASK_DATA_DIR/tzdata/version" "$TASK_DATA_DIR/zoneinfo/.version"
fi
printf 'ICU 78.3 and tzdata 2026b ready in %s\n' "$TASK_DATA_DIR"
