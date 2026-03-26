# Proposal

## Problem statement

no API exists to allow dynamically choosing buffering mode at runtime, i.e. there is no way for a program to switch stdin, stdout, or stderr between line-buffered (flush every new line), block-buffered (flush once buffer is full), or unbuffered (flush on every call) regardless of user intent.

## Motivating examples or use cases

[uutils/coreutils](https://github.com/uutils/coreutils) is rust rewrite of GNU coreutils, `stdbuf`
is one of those utilities, it lets user control the buffering mode of any program their invoke (GNU coreutils needs to satisfy `lib` while uutils must sasify both `libc` and rust's standard library), for example `stdbuf -oL uniq file.txt` runs `uniq` on `file.txt` with line-buffered stdout.

`stdbuf` sets the environment variables and injecting a shared library `libstdbuf.so` via
`LD_PRELOAD`, that library reads those variables and calls `setvbuf()` on the chosen C stdio stream.

this design is impossible to implement in rust. a utility cannot delegate the control of its own buffering
which breaks composability.

## Solution sketch

<!--
Please write down all the functions, types or traits that you propose here. Make sure you include the *full type signatures* (arguments, return type, trait bounds etc.).

You don't have to include the function bodies, but the signatures are a critical portion of the API and it is really difficult to evaluate the proposal without them.
-->

## Alternatives

<!--
Please also discuss alternative solutions to the problem. Include any reasoning for why you didn't suggest those as the primary solution.

Could this be written using existing APIs? If so, roughly what would that look like? Why does it need to be different? Could this be done as a crate on crates.io?
-->

## Links and related work

<!-- Provide links to any <https://internals.rust-lang.org> thread(s), github issues, approaches to this problem in other languages/libraries, or similar supporting information. -->

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


1. wrapping bufwriter only add the buffer not modifies the interal
2. stack allocated writes via self provider buffer a la libc
3. doublecheck screenshots i took for the vewctor passing
4. verify that the program can still override the config i mean for sure it can
because it's just another call
5. swtichwriter maybe bufferedwriter instead as the name
6. compare to vector api, `set_capacity`

output
```text
$ seq 1000000 | strace -e trace=write uniq 2>&1 | grep 'write(1' | wc -l
1682
$ seq 1000000 | strace -e trace=write stdbuf -o4096 uniq 2>&1 | grep 'write(1' | wc -l
1682
$ seq 1000000 | strace -e trace=write stdbuf -o256 uniq 2>&1 | grep 'write(1' | wc -l
26910
$ seq 1000000 | strace -e trace=write stdbuf -oL uniq 2>&1 | grep 'write(1' | wc -l
1000000
$ seq 1000000 | strace -e trace=write stdbuf -o0 uniq 2>&1 | grep 'write(1' | wc -l
1000000
```

```text
$ seq 1000000 | strace -e trace=read uniq 2>&1 | grep 'read(0' | wc -l
1683
$ seq 1000000 | strace -e trace=read stdbuf -i0 uniq 2>&1 | grep 'read(0' | wc -l
6888897
$ seq 1000000 | strace -e trace=read stdbuf -i4096 uniq 2>&1 | grep 'read(0' | wc -l
1683
$ seq 1000000 | strace -e trace=read stdbuf -iL uniq 2>&1 | grep 'read(0' | wc -l
seq: write error: Broken pipe
0
```

```text
$ strace -e trace=write uniq /nonexistent 2>&1 | grep 'write(2' | wc -l
4
$ strace -e trace=write stdbuf -e0 uniq /nonexistent 2>&1 | grep 'write(2' | wc -l
4
$ strace -e trace=write stdbuf -e4096 uniq /nonexistent 2>&1 | grep 'write(2' | wc -l
1
$ strace -e trace=write stdbuf -eL uniq /nonexistent 2>&1 | grep 'write(2' | wc -l
1
```

always push within capcity?
augment or shrink with unsafe to be sure? we don't fully reallocate
BufferingMode

check how Zig does that!



alias rebuild-uutils='cd /home/victorprokhorov/coreutils && STAGE1_SYSROOT=$(rustup run stage1 rustc --print sysroot) && CARGO_TARGET_DIR=target/stage1 RUSTC="$STAGE1_SYSROOT/bin/rustc" RUSTFLAGS="--sysroot $STAGE1_SYSROOT" cargo build -p uu_stdbuf_libstdbuf -p uu_stdbuf -p uu_uniq'

