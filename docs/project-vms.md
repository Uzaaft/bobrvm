# Project VMs

`bobrvm up` searches the current directory and its parents for `bobrvm.toml`,
then boots the described VM. Relative paths resolve against the project root.

```toml
memory = 2048
cpus = 2
kernel = "boot/Image"
initrd = "boot/initrd"
forwards = ["2222:22"]
```

The project directory is shared over virtio-9p by default. Set `share = false`
to disable it or `share-readonly = true` to prevent guest writes at the host
boundary. `bobrvm up --help` lists all keys.

## Warm state

Press <kbd>Ctrl</kbd>+<kbd>B</kbd> <kbd>z</kbd> to suspend. The next `bobrvm up`
restores RAM, processes, and disks. Warm state lives under
`$XDG_CONFIG_HOME/bobrvm/projects/`, or `~/.config/bobrvm/projects/` when
`XDG_CONFIG_HOME` is unset. It is never written to the repository.

- `bobrvm up --fresh` discards warm state and boots from scratch.
- `bobrvm up --detach` starts the project in the background.
- `bobrvm status`, `bobrvm suspend`, and `bobrvm halt` manage a detached VM.
- `engine = "vz"` selects Apple's Virtualization.framework backend.

A `provision = ["command", ...]` list runs once on the first cold boot. Suspend
after provisioning to use the result as the base for later starts and forks.

## Disposable work

`bobrvm fork` runs a copy-on-write clone of the native engine's warm state. The
clone's memory and writable disks are removed on exit; the base state is not
modified. Port forwards are omitted so multiple forks can run concurrently.

`bobrvm exec -- <command>` runs a command in a disposable clone and prints its
output. `bobrvm ssh` connects through the host port forwarded to guest port 22;
set `ssh-user` and run sshd in the guest.

## Agent sandboxes

`bobrvm mcp` exposes disposable forks over the Model Context Protocol:

```json
{
  "mcpServers": {
    "bobrvm": { "command": "bobrvm", "args": ["mcp"] }
  }
}
```

The server provides `sandbox_start`, `sandbox_exec`, `sandbox_output`,
`sandbox_list`, and `sandbox_stop`. It requires native-engine warm state.

MCP sandboxes preserve the warm guest's device layout, but disable host network
connections, port forwards, Docker socket forwarding, and host-directory access
before restore. The 9p device refuses requests and does not reopen saved host
file handles. Writable disks and RAM use private clones. Read-only disk images
remain shared. Data already present in the warm guest's RAM or disks remains
available; prepare the warm image with the data you intend agents to have.
Ordinary `fork` and `exec` retain the project's host-access settings.

Each `sandbox_exec` runs a separate `sh -c` with stdin redirected from `/dev/null`.
Scripts can include newlines, quotes, comments, and `exit`; working-directory
changes and shell variables do not carry into the next call. Files in the sandbox
do persist until it is stopped. Scripts are limited to 768 bytes, with NUL
rejected and an additional 1023-byte limit on the encoded console line. Oversized
scripts fail before execution. Put larger scripts in the warm image and invoke
them by path. The warm guest must be parked at an idle, cooperative shell prompt;
console framing is not authentication against a malicious guest. Commands that
alter the console itself can still disrupt subsequent execution.

The server admits one tool call at a time. Ping and MCP cancellation remain
responsive during execution; other tool calls return a busy error. A matching
`sandbox_stop` interrupts the active command. Timeout, execution transport failure,
and cancellation destroy the entire affected sandbox, including background
processes. Create a new sandbox after one of these outcomes. Other sandboxes stay
alive. Invalid arguments leave the sandbox intact.

Cancel an active request with an MCP `notifications/cancelled` notification whose
`params.requestId` matches the original request ID (including its string or integer
type). Cancellation notifications receive no reply and suppress the cancelled
call's reply when it has not already been sent, following the
[MCP cancellation contract](https://modelcontextprotocol.io/specification/2024-11-05/basic/utilities/cancellation).
Closing MCP stdin also cancels active work and disposes of all sandboxes. Shutdown
allows two seconds for graceful VM cleanup before forced child termination; the
parent owns the fork directory so it can remove private state after either path.

For direct host-to-guest connectivity without port forwards, use `network = "shared"`
and install the bundled privileged helper. See [Networking](networking.md).
