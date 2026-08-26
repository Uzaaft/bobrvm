//! CLI subcommand dispatcher.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const Config = @import("Config.zig");
pub const run = @import("run.zig");
pub const up = @import("up.zig");
pub const fork = @import("fork.zig");
pub const mcp = @import("mcp.zig");
pub const vz = @import("vz.zig");
pub const ctl = @import("ctl.zig");
pub const exec = @import("exec.zig");
pub const bench = @import("bench.zig");
pub const bench_command = @import("bench_command.zig");
pub const bench_host = @import("bench_host.zig");
pub const ssh = @import("ssh.zig");
pub const create = @import("create.zig");
pub const list = @import("list.zig");
pub const start = @import("start.zig");
pub const delete = @import("delete.zig");
pub const docker = @import("docker.zig");
pub const docker_host = @import("docker_host.zig");
pub const install_cli = @import("install_cli.zig");

const log = std.log.scoped(.cli);

pub const Subcommand = enum {
    run,
    up,
    fork,
    exec,
    bench_warm,
    bench_command,
    bench_host,
    ssh,
    mcp,
    vz_run,
    status,
    halt,
    suspend_vm,
    create,
    list,
    start,
    delete,
    install_cli,
    docker_host,
    help,
    version,
};

pub const DispatchError = error{
    UnknownSubcommand,
    HelpRequested,
    VersionRequested,
};

pub fn dispatch(alloc: Allocator, minimal: std.process.Init.Minimal) !void {
    var args = minimal.args.iterate();
    _ = args.skip();

    const subcmd_str = args.next() orelse {
        printUsage();
        return DispatchError.HelpRequested;
    };

    const subcmd = parseSubcommand(subcmd_str) orelse {
        log.err("unknown subcommand: {s}", .{subcmd_str});
        printUsage();
        return DispatchError.UnknownSubcommand;
    };

    switch (subcmd) {
        .run => try run.execute(alloc, &args),
        .up => try up.execute(alloc, &args, minimal.environ),
        .fork => try fork.execute(alloc, &args),
        .exec => try exec.execute(alloc, &args),
        .bench_warm => try bench.execute(alloc, &args),
        .bench_command => try bench_command.execute(alloc, &args, minimal.environ),
        .bench_host => try bench_host.execute(alloc, &args),
        .ssh => try ssh.execute(alloc, &args),
        .mcp => try mcp.execute(alloc, &args, minimal.environ),
        .vz_run => try vz.execute(alloc, &args),
        .status => try ctl.execute(alloc, .status),
        .halt => try ctl.execute(alloc, .halt),
        .suspend_vm => try ctl.execute(alloc, .@"suspend"),
        .create => try create.execute(alloc, &args),
        .list => try list.execute(alloc),
        .start => try start.execute(alloc, &args),
        .delete => try delete.execute(alloc, &args),
        .install_cli => try install_cli.execute(alloc, &args),
        .docker_host => try docker_host.execute(alloc, &args, minimal.environ),
        .help => {
            printUsage();
            return DispatchError.HelpRequested;
        },
        .version => {
            printVersion();
            return DispatchError.VersionRequested;
        },
    }
}

fn parseSubcommand(str: []const u8) ?Subcommand {
    const map = std.StaticStringMap(Subcommand).initComptime(.{
        .{ "run", .run },
        .{ "up", .up },
        .{ "fork", .fork },
        .{ "exec", .exec },
        .{ "bench-warm", .bench_warm },
        .{ "bench-command", .bench_command },
        .{ "bench-host", .bench_host },
        .{ "ssh", .ssh },
        .{ "mcp", .mcp },
        .{ "vz-run", .vz_run },
        .{ "status", .status },
        .{ "halt", .halt },
        .{ "suspend", .suspend_vm },
        .{ "create", .create },
        .{ "list", .list },
        .{ "ls", .list },
        .{ "start", .start },
        .{ "delete", .delete },
        .{ "rm", .delete },
        .{ "install-cli", .install_cli },
        .{ "docker-host", .docker_host },
        .{ "help", .help },
        .{ "--help", .help },
        .{ "-h", .help },
        .{ "version", .version },
        .{ "--version", .version },
        .{ "-v", .version },
    });
    return map.get(str);
}

fn printUsage() void {
    const usage =
        \\bobrvm - Linux virtualization for macOS
        \\
        \\Usage: bobrvm <command> [options]
        \\
        \\Commands:
        \\  up               Boot the project's bobrvm.toml (resumes warm state)
        \\  fork             Run a disposable clone of the project's warm state
        \\  exec -- <cmd>    Run a command in a disposable clone and print output
        \\  ssh              SSH into the project's guest via a forwarded port
        \\  status           Show the project's detached runner and warm state
        \\  suspend          Save the detached runner's state and stop it
        \\  halt             Stop the project's detached runner
        \\  bench-warm       Measure warm-restore latency over N trials
        \\  bench-command    Measure command latency and runtime energy
        \\  bench-host       Measure macOS CPU, wakeups, memory, I/O, and energy
        \\  mcp              Serve sandboxes to AI agents over MCP (stdio)
        \\  vz-run           Boot on Virtualization.framework (lite engine, experimental)
        \\  run              Run a VM directly with options
        \\  create <name>    Create a named VM configuration
        \\  list, ls         List saved VM configurations
        \\  start <name>     Start a saved VM by name
        \\  delete, rm       Delete a saved VM configuration
        \\  install-cli      Install app-bundled CLI symlinks safely
        \\  docker-host      Manage the shared VZ-backed Docker runtime
        \\  help             Show this help message
        \\  version          Show version information
        \\
        \\Examples:
        \\  bobrvm up
        \\  bobrvm run --memory 1024 --disk root.raw
        \\  bobrvm create myvm --memory 2048 --disk vm.raw
        \\  bobrvm start myvm
        \\  bobrvm list
        \\
        \\Run 'bobrvm <command> --help' for command-specific help.
        \\
    ;
    _ = std.c.write(std.posix.STDOUT_FILENO, usage.ptr, usage.len);
}

fn printVersion() void {
    const version = "bobrvm 0.1.0\n";
    _ = std.c.write(std.posix.STDOUT_FILENO, version.ptr, version.len);
}
