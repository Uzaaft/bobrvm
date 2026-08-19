---
name: writing-commit-messages
description: >-
  Writes commit messages and applies commits for bobrvm. Activates when
  the user asks to commit, write a commit message, draft a commit
  message, or similar.
---

# Writing Commit Messages

Write commit messages that follow commit style guidelines for the project.

## Format

```
<subsystem>: <summary>

<reference issues/PRs/etc.>

<long form description>
```

## Rules

### Subject line


- **Subsystem**: the subsystem, determined from the changed file paths:
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

- If `.jj` is present, use `jj` instead of `git` for all commands.
- Run a diff to see what changes are present since the last commit.
- Identify the subsystem from the changed file paths.
- Identify any referenced issues/PRs from the diff context or
  branch name.
- Draft the commit message following the format above.
- Apply the commit
- Don't push the commit; leave that to the user.
