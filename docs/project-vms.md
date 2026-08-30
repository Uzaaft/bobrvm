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
