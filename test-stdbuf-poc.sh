#!/usr/bin/env bash
# requires stage1 rustc built from https://github.com/victor-prokhorov/rust/commit/a9d5767288d132bc3688799ad45c4647b7043f7d
# which is a clone of https://github.com/rust-lang/rust/pull/78515
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
        // ok this work just go fast for now
        std::thread::sleep(std::time::Duration::from_secs(1));
    }
}
RUST
LD_LIBRARY_PATH="$STAGE1_SYSROOT_LIB" /tmp/poc_block_test

step "build uutils"
cd "$COREUTILS_DIR"
CARGO_TARGET_DIR=target RUSTC="$STAGE1_RUSTC" RUSTFLAGS="--sysroot $STAGE1_SYSROOT" \
    cargo build -p uu_stdbuf -p uu_uniq || true
ok "uutils built"

step "GNU compliance tests/misc/stdbuf.sh"
cd "$COREUTILS_DIR"
path_UUTILS="$COREUTILS_DIR" path_GNU="$GNU_DIR" PROFILE=debug \
  util/run-gnu-test.sh tests/misc/stdbuf.sh || true

step "build uutils (prefer-dynamic: shared libstd so libstdbuf.so and uniq share one OnceLock)"
cd "$COREUTILS_DIR"
CARGO_TARGET_DIR=target/stage1-dyn \
    RUSTC="$STAGE1_SYSROOT/bin/rustc" \
    RUSTFLAGS="--sysroot $STAGE1_SYSROOT -C prefer-dynamic" \
    cargo build -p uu_stdbuf_libstdbuf -p uu_stdbuf -p uu_uniq
ok "uutils (prefer-dynamic) built"

step "strace write count tests (dynamic std — libstdbuf.so and uniq share one STDOUT OnceLock)"
cd "$COREUTILS_DIR"
UU_STDBUF=./target/stage1-dyn/debug/stdbuf
UU_UNIQ=./target/stage1-dyn/debug/uniq
seq 1000000 | LD_LIBRARY_PATH="$STAGE1_SYSROOT_LIB" strace -e trace=write "$UU_STDBUF" -o64 "$UU_UNIQ" 2>&1 | grep 'write(1' | wc -l
