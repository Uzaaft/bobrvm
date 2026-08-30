# Contributing to bobrvm

Bug fixes, focused features, tests, and documentation improvements are welcome.
For a large feature or architectural change, open a discussion before investing
in an implementation.

## Before sending a change

Read [HACKING.md](HACKING.md), then build and test the smallest relevant target.
Keep changes focused and include tests for behavior that can regress.

The project follows a few non-negotiable rules:

- Validate guest-controlled lengths, addresses, queue entries, and protocol data.
- Preserve renderer-thread isolation and GPU synchronization.
- Make ownership and lifetime explicit across Zig, C, and Swift boundaries.
- Do not add an external runtime dependency without prior discussion.
- Keep lines within 100 columns and use four-space indentation.

Use comments for contracts, invariants, protocol semantics, and non-obvious
constraints. Do not narrate the implementation.

## Checks

Run the checks relevant to the files you changed:

```sh
zig build test -Dtest-filter=<name>
zig fmt --check .
alejandra --check .
swift-format lint -r macos/Sources
```

Use `nix build .#test` for the complete Zig test derivation. Swift and Xcode are
not managed by Nix; macOS application tests use:

```sh
nix develop -c macos/build.nu --action test
```

## Changes

The repository uses Jujutsu. Describe focused changes with a conventional
commit message, for example:

```text
fix(hypervisor): correct memory region alignment
```
