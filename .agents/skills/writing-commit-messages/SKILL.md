---
name: writing-commit-messages
description: >-
  Writes commit messages and applies commits for bobrvm. Activates when
  the user asks to commit, write a commit message, draft a commit
  message, or similar.
---

# Writing Commit Messages

Write commit messages that follow bobrvm's commit style, and apply them
with Jujutsu. This repository is jj-colocated: never use `git commit`.

## Format

```
<type>(<scope>): <summary>

<reference issues/PRs/etc.>

<long form description>
```

## Rules

### Subject line

- **Type**: one of `feat`, `fix`, `build`, `docs`, `test`, `perf`,
  `refactor`, `ci`, `chore`. Bare `<scope>: <summary>` (no type) also
  appears in history and is acceptable for small mechanical changes;
  prefer the typed form.
- **Scope**: the subsystem, determined from the changed file paths:
  `hypervisor`, `virtio`, `pci`, `gic`, `gpu`, `renderer`, `net`,
  `machine`, `snapshot`, `cli`, `agent`, `guest-tools`, `p9`,
  `runtime`, `apprt`, `console`. Changes to the macOS app use `macos`,
  the Linux frontends `linux` or `gtk`, packaging `nix` or `brew`, the
  build system `build`, CI `ci`, vendored GPU stack `third-party`.
- **Summary**: lowercase start, imperative mood, no trailing period.
  Keep the whole subject line under 60 characters.

### References

- If the change relates to a GitHub issue, PR, or discussion, list the
  relevant numbers on their own lines after the subject, separated by a
  blank line. E.g. `#1234`
- If there are no references, omit this section entirely (no blank
  line).

### Long form description

- Describe **what changed**, **what the previous behavior was**, and
  **how the new behavior works** at a high level.
- Use plain prose, not bullet points. Wrap lines at ~72 characters.
- Focus on the _why_ and _how_ rather than restating the diff.
- Keep the tone direct and technical without filler phrases.
- Don't exceed a handful of paragraphs; less is more.
- Assume reader has no access to any agentic coding sessions

## Workflow

Use `jj` for every step. The colocated git repo is written by jj's
export; commits made with `git commit` get clobbered when jj exports
its working-copy change over git HEAD.

- `jj st` and `jj diff` to see what the working-copy change contains.
- Identify the scope from the changed file paths.
- Identify any referenced issues/PRs from the diff context.
- Draft the message following the format above.
- Apply it to the working-copy change, one `-m` per paragraph:

  ```sh
  jj describe -m "type(scope): summary" -m "long form paragraph"
  ```

- Start the next change with `jj new`.
- Don't push; leave that to the user.

### Pitfalls

- Never put backticks in `-m` arguments — the shell runs them as a
  subshell and the words vanish. Reword, or single-quote the argument.
- Do not fall back to `git commit`, even with signing disabled: 1Password
  commit signing fails in non-interactive shells, and jj's export will
  reset git HEAD over the commit anyway.
- `jj` auto-snapshots the working copy; there is no staging step and
  nothing to `git add`.
