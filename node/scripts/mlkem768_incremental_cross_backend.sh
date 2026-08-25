#!/usr/bin/env bash
set -euo pipefail

# node/ is the parent of scripts/.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORTABLE_TARGET_DIR="$ROOT/target/libcrux-portable"

case "$(uname -m)" in
  x86_64)
    SIMD_NAME="AVX2"
    SIMD_TARGET_DIR="$ROOT/target/libcrux-avx2"
    ;;
  arm64 | aarch64)
    SIMD_NAME="NEON"
    SIMD_TARGET_DIR="$ROOT/target/libcrux-neon"
    ;;
  *)
    echo "unsupported host architecture for libcrux SIMD check: $(uname -m)" >&2
    exit 1
    ;;
esac

# These directories must stay distinct: Cargo caches libcrux's SIMD selection.
if [[ "$PORTABLE_TARGET_DIR" == "$SIMD_TARGET_DIR" ]]; then
  echo "portable and SIMD builds must use separate CARGO_TARGET_DIR values" >&2
  exit 1
fi

PORTABLE_DUMP="$PORTABLE_TARGET_DIR/mlkem768-encaps1-state.hex"
SIMD_DUMP="$SIMD_TARGET_DIR/mlkem768-encaps1-state.hex"
rm -f "$PORTABLE_DUMP" "$SIMD_DUMP"

cd "$ROOT"

echo "=== ML-KEM-768 incremental portable suite ===" >&2
CARGO_TARGET_DIR="$PORTABLE_TARGET_DIR" \
LIBCRUX_DISABLE_SIMD128=1 \
LIBCRUX_DISABLE_SIMD256=1 \
  cargo test -p raven-core --features mlkem768-incremental-lab \
    --lib mlkem768_incremental

echo "=== ML-KEM-768 incremental portable Encaps1 dump ===" >&2
CARGO_TARGET_DIR="$PORTABLE_TARGET_DIR" \
LIBCRUX_DISABLE_SIMD128=1 \
LIBCRUX_DISABLE_SIMD256=1 \
RAVEN_DUMP_ENCAPS1_STATE=1 \
RAVEN_DUMP_ENCAPS1_STATE_PATH="$PORTABLE_DUMP" \
  cargo test -p raven-core --features mlkem768-incremental-lab \
    --lib mlkem768_incremental::feature_smoke::dump_mlkem768_incremental_encaps1_state \
    -- --exact --ignored

if [[ ! -s "$PORTABLE_DUMP" ]]; then
  echo "portable Encaps1 dump was not written: $PORTABLE_DUMP" >&2
  exit 1
fi

echo "=== ML-KEM-768 incremental $SIMD_NAME suite ===" >&2
(
  unset LIBCRUX_DISABLE_SIMD128 LIBCRUX_DISABLE_SIMD256
  CARGO_TARGET_DIR="$SIMD_TARGET_DIR" \
    cargo test -p raven-core --features mlkem768-incremental-lab \
      --lib mlkem768_incremental

  echo "=== ML-KEM-768 incremental $SIMD_NAME Encaps1 dump ===" >&2
  CARGO_TARGET_DIR="$SIMD_TARGET_DIR" \
  RAVEN_DUMP_ENCAPS1_STATE=1 \
  RAVEN_DUMP_ENCAPS1_STATE_PATH="$SIMD_DUMP" \
    cargo test -p raven-core --features mlkem768-incremental-lab \
      --lib mlkem768_incremental::feature_smoke::dump_mlkem768_incremental_encaps1_state \
      -- --exact --ignored
)

if [[ ! -s "$SIMD_DUMP" ]]; then
  echo "$SIMD_NAME Encaps1 dump was not written: $SIMD_DUMP" >&2
  exit 1
fi

echo "=== Comparing portable and $SIMD_NAME Encaps1 states ===" >&2
diff -u "$PORTABLE_DUMP" "$SIMD_DUMP"

echo "ML-KEM-768 incremental portable/$SIMD_NAME states are identical" >&2
