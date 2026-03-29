# Proposal

## Problem statement

no API exists to allow dynamically choosing buffering mode at runtime, i.e. there is no way for a program to switch stdin, stdout, or stderr between line-buffered (flush every new line), block-buffered (flush once buffer is full), or unbuffered (flush on every call) regardless of user intent.

## Motivating examples or use cases

[uutils/coreutils](https://github.com/uutils/coreutils) is rust rewrite of GNU coreutils, `stdbuf`
is one of those utilities, it lets user control the buffering mode of any program their invoke (GNU coreutils needs to satisfy `lib` while uutils must sasify both `libc` and rust's standard library), for example `stdbuf -oL uniq file.txt` runs `uniq` on `file.txt` with line-buffered stdout.

`stdbuf` sets the environment variables and injecting a shared library `libstdbuf.so` via
`LD_PRELOAD`, that library reads those variables and calls `setvbuf()` on the chosen C stdio stream.

as of today this design is impossible to implement in rust. a utility binary cannot delegate the control of its own buffering
which breaks composability.

## Solution sketch

Add a `BufferingMode` enum and two traits — `BufferedWrite` and `BufferedRead` — to `std::io`, together with the public `BufferedWriter<W>` and `BufferedReader<R>` structs that back them. Wire all three standard streams to use these types internally.

### `BufferingMode`

```rust
#[non_exhaustive]
pub enum BufferingMode {
    /// Each write goes directly to the underlying fd — no internal buffer used.
    Unbuffered,
    /// Flush when the internal buffer is full (block buffering).
    Buffered,
    /// Flush after every newline. Default for stdout when connected to a terminal.
    LineBuffered,
}
```

### Traits

```rust
pub trait BufferedWrite: Write {
    fn buffering_mode(&self) -> BufferingMode;
    fn set_buffering_mode(&mut self, mode: BufferingMode);
    fn buffer_capacity(&self) -> usize;
    fn set_buffer_capacity(&mut self, capacity: usize);
    fn set_buffer(&mut self, buf: Vec<u8>);
}

pub trait BufferedRead: Read {
    fn buffering_mode(&self) -> BufferingMode;
    fn set_buffering_mode(&mut self, mode: BufferingMode);
    fn buffer_capacity(&self) -> usize;
    fn set_buffer_capacity(&mut self, capacity: usize);
    fn set_buffer(&mut self, buf: Vec<u8>);
}
```

### Public structs

`BufferedWriter<W: Write>` wraps a `BufWriter<W>` and a `mode: BufferingMode` field.
`set_buffering_mode` flips the enum only — zero allocation, no `Vec` realloc.
The `Write` impl dispatches on `mode`: `Unbuffered` bypasses the inner `BufWriter` and writes directly; `LineBuffered` flushes after every `\n`; `Buffered` delegates to `BufWriter` as-is.

`set_buffer_capacity` grows in place (`reserve`) or shrinks (`shrink_to`), flushing first only if the live data in the buffer exceeds the new capacity.
`set_buffer` always flushes before replacing the `Vec`.

`BufferedReader<R: Read>` mirrors the above for reads. In `Unbuffered` mode it bypasses the inner `BufReader` and calls `read` directly on the underlying source; the other two modes go through `BufReader` (line buffering on input is a terminal/OS concern outside this scope).

### Standard stream changes

- `Stdout` / `StdoutLock`: inner type changes from `LineWriter<StdoutRaw>` → `BufferedWriter<StdoutRaw>`. Default mode: `LineBuffered` (preserves current behavior).
- `Stderr` / `StderrLock`: inner type changes from `StderrRaw` → `BufferedWriter<StderrRaw>`. Default mode: `Unbuffered` (preserves current behavior).
- `Stdin` / `StdinLock`: inner type changes from `BufReader<StdinRaw>` → `BufferedReader<StdinRaw>`. Default mode: `Buffered` (preserves current behavior).

All three lock types implement the corresponding trait and expose it under the `stdio_buffering` feature gate.

### `stdbuf` proof of concept

A working implementation exists in [uutils/coreutils](https://github.com/uutils/coreutils) using a prototype stdlib branch. `libstdbuf.so` is injected via `LD_PRELOAD`, reads `_STDBUF_{I,O,E}` env vars, and calls `set_buffering_mode` / `set_buffer_capacity` on the locked streams. `strace` write-count tests confirm correct behavior across all four modes (`-o0`, `-oL`, `-o256`, `-o4096`) for both individual and multicall binaries.

The key property enabling this is that `set_buffering_mode` is zero-allocation: it flips an enum field on the already-allocated `BufferedWriter`. There is no second buffer created, no realloc triggered.

## Alternatives

### Wrap stdout in `BufWriter::new(stdout().lock())`

This is the current workaround. It does not solve the problem: `BufWriter::new` allocates a second, independent `Vec<u8>` on top of the internal buffer that already exists in `Stdout`. The outer `BufWriter` dominates — it controls when data reaches the inner stream — but it cannot shrink, remove, or switch the inner buffer. The result is two live heap buffers simultaneously, and the caller cannot switch the inner stream to unbuffered or line-buffered mode at all.

### A crate on crates.io

A crate cannot reach inside `std`'s private `OnceLock`-initialized buffer. Any attempt requires either `unsafe` memory layout assumptions that break across `std` versions, or rebuilding a parallel `Stdout` type that conflicts with the real one (two separate locks, two separate buffers, no sharing between threads that hold different lock types).

### Have `std` read `_STDBUF_*` env vars during `OnceLock` initialization

This would let `stdbuf` work without any API changes, but it couples the standard library to a specific external tool's private env var protocol. Every Rust program would carry that logic; it cannot be extended to user-defined buffering needs.

### Only call `setvbuf()` (C stdio)

`setvbuf` controls the C `FILE*` layer. Rust's `Stdout` does not go through `FILE*` — it has its own independent `Vec<u8>` buffer. Calling `setvbuf` on `stdout` from a `LD_PRELOAD` library affects C code in the same process but has no effect on Rust's `std::io::stdout()`. Both layers must be configured independently.

## Links and related work

- Tracking issue: [rust-lang/rust#78515](https://github.com/rust-lang/rust/issues/78515) — original `stdout_switchable_buffering` proposal
- uutils stdbuf implementation: [uutils/coreutils — `src/uu/stdbuf`](https://github.com/uutils/coreutils/tree/main/src/uu/stdbuf)
- GNU `stdbuf` manual: <https://www.gnu.org/software/coreutils/manual/html_node/stdbuf-invocation.html>
- POSIX `setvbuf`: <https://pubs.opengroup.org/onlinepubs/9699919799/functions/setvbuf.html>

## What happens now?

This issue contains an API change proposal (or ACP) and is part of the libs-api team [feature lifecycle]. Once this issue is filed, the libs-api team will review open proposals as capability becomes available. Current response times do not have a clear estimate, but may be up to several months.

[feature lifecycle]: https://std-dev-guide.rust-lang.org/development/feature-lifecycle.html

## Possible responses

The libs team may respond in various different ways. First, the team will consider the *problem* (this doesn't require any concrete solution or alternatives to have been proposed):

- We think this problem seems worth solving, and the standard library might be the right place to solve it.
- We think that this probably doesn't belong in the standard library.

Second, if there's a concrete solution:

- We think this specific solution looks roughly right, approved, you or someone else should implement this. (Further review will still happen on the subsequent implementation PR.)
- We're not sure this is the right solution, and the alternatives or other materials don't give us enough information to be sure about that. Here are some questions we have that aren't answered, or rough ideas about alternatives we'd want to see discussed.
