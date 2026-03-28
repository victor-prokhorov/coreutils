#!/usr/bin/env bash
set -euo pipefail

COREUTILS_DIR=/home/victorprokhorov/coreutils
RUST_DIR=/home/victorprokhorov/rust-lang/rust
GNU_DIR=/home/victorprokhorov/gnu
STAGE1_SYSROOT="$RUST_DIR/build/aarch64-unknown-linux-gnu/stage1"
STAGE1_SYSROOT_LIB="$STAGE1_SYSROOT/lib/rustlib/aarch64-unknown-linux-gnu/lib"
STAGE1_RUSTC="$STAGE1_SYSROOT/bin/rustc"

ok()   { echo "  OK  $*"; }
fail() { echo "FAIL $*"; exit 1; }
step() { echo; echo "$*"; }

step "build stdlib"
cd "$RUST_DIR"
python3 x.py build library
ok "stdlib built"

step "toolchain check"
rustup run stage1 rustc --version | grep -q 'rustc' \
  || fail "stage1 toolchain not found"
ok "$(rustup run stage1 rustc --version)"
rustup run stage1 rustc --edition 2024 -C prefer-dynamic \
  -o /tmp/poc_api_check - <<'RUST' \
  || fail "stdio_buffering or set_buffering_mode not found in stage1 stdlib"
#![feature(stdio_buffering)]
use std::io::{self, BufferingMode, BufferedWrite, BufferedRead};
fn main() {
    io::stdout().lock().set_buffering_mode(BufferingMode::LineBuffered);
    io::stderr().lock().set_buffering_mode(BufferingMode::Unbuffered);
    io::stdin().lock().set_buffering_mode(BufferingMode::Buffered);
}
RUST
ok "stage1 stdlib has stdio_buffering and set_buffering_mode for all 3 streams"

step "block buffering test all lines must appear together at the end"
rustup run stage1 rustc --edition 2024 -C prefer-dynamic \
  -o /tmp/poc_block_test - <<'RUST' || fail "compile poc_block_test"
#![feature(stdio_buffering)]
use std::io::{self, BufferingMode, BufferedWrite};
fn main() {
    io::stdout().lock().set_buffering_mode(BufferingMode::Buffered);
    for line in ["1", "2", "3", "soleil"] {
        println!("{line}");
        std::thread::sleep(std::time::Duration::from_secs(1));
    }
}
RUST
LD_LIBRARY_PATH="$STAGE1_SYSROOT_LIB" /tmp/poc_block_test

step "build uutils + install into gnu (prefer-dynamic: shared libstd so libstdbuf.so and uniq share one OnceLock)"
cd "$COREUTILS_DIR"
export LD_LIBRARY_PATH="$STAGE1_SYSROOT_LIB"
CARGO_TARGET_DIR="$COREUTILS_DIR/target" \
    RUSTC="$STAGE1_RUSTC" \
    RUSTFLAGS="--sysroot $STAGE1_SYSROOT -C prefer-dynamic" \
    path_UUTILS="$COREUTILS_DIR" path_GNU="$GNU_DIR" PROFILE=debug \
    bash util/build-gnu.sh
ok "uutils (prefer-dynamic) built and installed into gnu"

step "GNU compliance tests/misc/stdbuf.sh"
cd "$COREUTILS_DIR"
path_UUTILS="$COREUTILS_DIR" path_GNU="$GNU_DIR" PROFILE=debug \
  util/run-gnu-test.sh tests/misc/stdbuf.sh || true

step "strace write count tests (dynamic std — libstdbuf.so and uniq share one STDOUT OnceLock)"
cd "$COREUTILS_DIR"
UU_STDBUF=./target/debug/stdbuf
UU_UNIQ=./target/debug/uniq

echo "  sys stdbuf: $(stdbuf --version 2>&1 | head -1)"
echo "  sys uniq:   $(uniq --version 2>&1 | head -1)"
echo "  UU stdbuf:  $($UU_STDBUF --version 2>&1 | head -1)"
echo "  UU uniq:    $($UU_UNIQ --version 2>&1 | head -1)"

# check_writes LABEL FD FLAG STDBUF UNIQ EXPECTED
# verifies uutils result is within 5% of expected (GNU reference)
check_writes() {
    local label=$1 fd=$2 flag=$3 stdbuf=$4 uniq=$5 expected=$6
    local got
    got=$(seq 1000 | strace -e trace=write "$stdbuf" "$flag" "$uniq" 2>&1 | grep "write($fd" | wc -l)
    local lo=$(( expected * 95 / 100 ))
    local hi=$(( expected * 105 / 100 + 5 ))
    if [[ $got -ge $lo && $got -le $hi ]]; then
        ok "$label: $got (expected ~$expected)"
    else
        fail "$label: got $got, expected ~$expected (range $lo–$hi)"
    fi
}

# seq 1000 produces 3893 bytes total
# GNU reference (scaled from 1M observation):
#   -o4096 → 1    (3893 bytes < buffer, all flushed at end)
#   -o256  → 16   (3893 / 256 ≈ 15.2)
#   -oL    → 1000 (line buffered)
#   -o0    → 1000 (unbuffered, GNU: 1 syscall/line via fwrite; uutils: 2 — content + \n separate)

check_writes "stdout -o4096" 1 -o4096 "$UU_STDBUF" "$UU_UNIQ" 1
check_writes "stdout -o256"  1 -o256  "$UU_STDBUF" "$UU_UNIQ" 16
check_writes "stdout -oL"    1 -oL    "$UU_STDBUF" "$UU_UNIQ" 1000
# uutils writes content and \n separately → 2 syscalls per line in unbuffered mode (GNU: 1)
check_writes "stdout -o0"    1 -o0    "$UU_STDBUF" "$UU_UNIQ" 2000
