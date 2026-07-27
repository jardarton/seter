# Agent instructions

## Project context

`CONTEXT.md` contains project domain terminology,
constraints, and accumulated design context.

## Working on the Rust CLI

The crate's unit tests are wired into the Nix build (`doCheck = 1` in
`nix/package.nix`), so `nix build .#seter` is the *only* thing that runs them by
default. That path costs about 56 seconds, because every invocation is a clean
release build of the crate plus its dependencies — there is no incremental
compilation across Nix builds.

Do not use it as your edit loop. When changing anything under
`crates/seter-cli`, work inside the dev shell instead:

```
cargo test
cargo clippy
```

The dev shell (`nix develop`, or automatically via direnv — `.envrc` is `use
flake`) provides `cargo`, `clippy`, `rustc`, `rustfmt`, and `nixfmt`. These
reuse `target/`, so a normal edit-test cycle is sub-second rather than a minute.

Run `nix build .#seter` once at the end, to confirm the packaged build and the
wrapper still work. It is a final check, not a feedback loop.

## Running the flake checks

Use plain `nix flake check`. Do not add `--all-systems`.

`systems` is `nix-systems/default-linux`, so the flake declares both
`x86_64-linux` and `aarch64-linux`. By default `nix flake check` only evaluates
the current system and prints a note that it omitted the incompatible one —
that note is expected, not a problem to fix. Passing `--all-systems` adds about
64 seconds of pure evaluation for the `aarch64-linux` check set, roughly
doubling evaluation time, and an x86_64 machine cannot build those outputs
anyway.

The same applies to explicit attribute paths: build
`.#checks.x86_64-linux.<name>`, not the `aarch64-linux` equivalents, unless you
are deliberately testing aarch64 support on an aarch64 host or a remote builder
that provides it.

Also ignore the `running 0 flake checks` line in the output. It counts only
legacy-style checks; the per-system `checks` outputs are still evaluated and
built.
