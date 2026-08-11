//! Stage-2 init executed from the writable virtio root filesystem.

const std = @import("std");

const linux = std.os.linux;
const rootfs_contents = "bobrvm-root-filesystem\n";
const persisted_contents = "bobrvm-root-write-ok\n";
const console_input = "bobrvm-input-ok";
const guest_mac = [6]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
const gateway_mac = [6]u8{ 0x52, 0x55, 0x0a, 0x00, 0x02, 0x02 };
const guest_ip = [4]u8{ 10, 0, 2, 15 };
const gateway_ip = [4]u8{ 10, 0, 2, 2 };

pub fn main() noreturn {
    const debug_port_available = linux.syscall3(.ioperm, 0xe9, 1, 1) == 0;
    if (!readExactSmall("/sys/devices/system/cpu/online", "0-1\n")) {
        if (debug_port_available) emit("BOBRVM_SMP_FAILED\n");
        restart();
    }
    if (debug_port_available) emit("BOBRVM_SMP_OK\n");
    if (!readExact("/rootfs-marker", rootfs_contents)) {
        if (debug_port_available) emit("BOBRVM_ROOTFS_CONTENT_FAILED\n");
        restart();
    }
    if (!writeExact("/bobrvm-write-marker", persisted_contents)) {
        if (debug_port_available) emit("BOBRVM_ROOTFS_WRITE_FAILED\n");
        restart();
    }
    const remount_flags = linux.MS.RDONLY | linux.MS.REMOUNT;
    if (linux.errno(linux.mount(null, "/", null, remount_flags, 0)) != .SUCCESS) {
        if (debug_port_available) emit("BOBRVM_ROOTFS_REMOUNT_FAILED\n");
        restart();
    }
    if (debug_port_available) emit("BOBRVM_ROOTFS_BOOT_OK\n");
    if (commandLineContains("bobrvm.console_test=1")) {
        if (debug_port_available) emit("BOBRVM_CONSOLE_INPUT_READY\n");
        if (!readConsoleLine(console_input)) {
            if (debug_port_available) emit("BOBRVM_CONSOLE_INPUT_FAILED\n");
            restart();
        }
        if (debug_port_available) emit("BOBRVM_CONSOLE_INPUT_OK\n");
    }
    if (commandLineContains("bobrvm.network_test=1")) {
        if (!probeGatewayArp()) {
            if (debug_port_available) emit("BOBRVM_NETWORK_FAILED\n");
            restart();
        }
        if (debug_port_available) emit("BOBRVM_NETWORK_OK\n");
    }
    restart();
}

fn probeGatewayArp() bool {
    const interface_index = bringUpInterface("eth0") orelse {
        emit("BOBRVM_NETWORK_NO_INTERFACE\n");
        return false;
    };
    const protocol = std.mem.nativeToBig(u16, 0x0806);
    const result = linux.socket(linux.AF.PACKET, linux.SOCK.RAW, protocol);
    if (linux.errno(result) != .SUCCESS) {
        emit("BOBRVM_NETWORK_SOCKET_FAILED\n");
        return false;
    }
    const fd: i32 = @intCast(result);
    defer _ = linux.close(fd);

    const address = linux.sockaddr.ll{
        .protocol = protocol,
        .ifindex = interface_index,
        .hatype = 0,
        .pkttype = 0,
        .halen = guest_mac.len,
        .addr = guest_mac ++ .{ 0, 0 },
    };
    if (linux.errno(linux.bind(fd, @ptrCast(&address), @sizeOf(linux.sockaddr.ll))) != .SUCCESS) {
        emit("BOBRVM_NETWORK_BIND_FAILED\n");
        return false;
    }
    const request = arpRequest();
    const sent = linux.sendto(fd, &request, request.len, 0, null, 0);
    if (linux.errno(sent) != .SUCCESS or sent != request.len) {
        emit("BOBRVM_NETWORK_SEND_FAILED\n");
        return false;
    }

    var response: [128]u8 = undefined;
    for (0..4) |_| {
        const count = linux.recvfrom(fd, &response, response.len, 0, null, null);
        if (linux.errno(count) != .SUCCESS) {
            emit("BOBRVM_NETWORK_RECEIVE_FAILED\n");
            return false;
        }
        if (validArpReply(response[0..count])) return true;
    }
    emit("BOBRVM_NETWORK_REPLY_INVALID\n");
    return false;
}

fn bringUpInterface(name: []const u8) ?i32 {
    if (name.len >= linux.IFNAMESIZE) return null;
    const result = linux.socket(linux.AF.INET, linux.SOCK.DGRAM, 0);
    if (linux.errno(result) != .SUCCESS) return null;
    const fd: i32 = @intCast(result);
    defer _ = linux.close(fd);

    var request = std.mem.zeroes(linux.ifreq);
    @memcpy(request.ifrn.name[0..name.len], name);
    if (linux.errno(linux.ioctl(fd, linux.SIOCGIFFLAGS, @intFromPtr(&request))) != .SUCCESS) {
        return null;
    }
    request.ifru.flags.UP = true;
    if (linux.errno(linux.ioctl(fd, linux.SIOCSIFFLAGS, @intFromPtr(&request))) != .SUCCESS) {
        return null;
    }
    if (linux.errno(linux.ioctl(fd, linux.SIOCGIFINDEX, @intFromPtr(&request))) != .SUCCESS) {
        return null;
    }
    return request.ifru.ivalue;
}

fn arpRequest() [42]u8 {
    var frame: [42]u8 = @splat(0);
    @memset(frame[0..6], 0xff);
    @memcpy(frame[6..12], &guest_mac);
    std.mem.writeInt(u16, frame[12..14], 0x0806, .big);
    std.mem.writeInt(u16, frame[14..16], 1, .big);
    std.mem.writeInt(u16, frame[16..18], 0x0800, .big);
    frame[18] = 6;
    frame[19] = 4;
    std.mem.writeInt(u16, frame[20..22], 1, .big);
    @memcpy(frame[22..28], &guest_mac);
    @memcpy(frame[28..32], &guest_ip);
    @memcpy(frame[38..42], &gateway_ip);
    return frame;
}

fn validArpReply(frame: []const u8) bool {
    if (frame.len < 42) return false;
    return std.mem.eql(u8, frame[0..6], &guest_mac) and
        std.mem.eql(u8, frame[6..12], &gateway_mac) and
        std.mem.readInt(u16, frame[12..14], .big) == 0x0806 and
        std.mem.readInt(u16, frame[20..22], .big) == 2 and
        std.mem.eql(u8, frame[22..28], &gateway_mac) and
        std.mem.eql(u8, frame[28..32], &gateway_ip);
}

fn commandLineContains(parameter: []const u8) bool {
    const result = linux.open("/proc/cmdline", .{}, 0);
    if (linux.errno(result) != .SUCCESS) return false;
    const fd: i32 = @intCast(result);
    defer _ = linux.close(fd);

    var buffer: [4096]u8 = undefined;
    const count = linux.read(fd, &buffer, buffer.len);
    if (linux.errno(count) != .SUCCESS) return false;
    return std.mem.indexOf(u8, buffer[0..count], parameter) != null;
}

fn readConsoleLine(expected: []const u8) bool {
    const result = linux.open("/dev/ttyS0", .{}, 0);
    if (linux.errno(result) != .SUCCESS) return false;
    const fd: i32 = @intCast(result);
    defer _ = linux.close(fd);

    var buffer: [64]u8 = undefined;
    var len: usize = 0;
    while (len < buffer.len) {
        const count = linux.read(fd, buffer[len..].ptr, buffer.len - len);
        if (linux.errno(count) != .SUCCESS or count == 0) return false;
        len += count;
        if (std.mem.indexOfScalar(u8, buffer[0..len], '\n')) |newline| {
            return std.mem.eql(u8, buffer[0..newline], expected);
        }
    }
    return false;
}

fn readExact(path: [:0]const u8, expected: []const u8) bool {
    const result = linux.open(path, .{}, 0);
    if (linux.errno(result) != .SUCCESS) return false;
    const fd: i32 = @intCast(result);
    defer _ = linux.close(fd);

    var buffer: [rootfs_contents.len]u8 = undefined;
    const count = linux.read(fd, &buffer, buffer.len);
    if (linux.errno(count) != .SUCCESS or count != expected.len) return false;
    return std.mem.eql(u8, buffer[0..expected.len], expected);
}

fn readExactSmall(path: [:0]const u8, expected: []const u8) bool {
    if (expected.len > 32) return false;
    const result = linux.open(path, .{}, 0);
    if (linux.errno(result) != .SUCCESS) return false;
    const fd: i32 = @intCast(result);
    defer _ = linux.close(fd);

    var buffer: [32]u8 = undefined;
    const count = linux.read(fd, &buffer, buffer.len);
    if (linux.errno(count) != .SUCCESS or count != expected.len) return false;
    return std.mem.eql(u8, buffer[0..expected.len], expected);
}

fn writeExact(path: [:0]const u8, bytes: []const u8) bool {
    const flags: linux.O = .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .SYNC = true,
    };
    const result = linux.open(path, flags, 0o644);
    if (linux.errno(result) != .SUCCESS) return false;
    const fd: i32 = @intCast(result);
    defer _ = linux.close(fd);

    const count = linux.write(fd, bytes.ptr, bytes.len);
    if (linux.errno(count) != .SUCCESS or count != bytes.len) return false;
    return linux.errno(linux.fsync(fd)) == .SUCCESS;
}

fn restart() noreturn {
    std.posix.reboot(.{ .RESTART = {} }) catch {};
    linux.exit_group(1);
}

fn emit(bytes: []const u8) void {
    for (bytes) |byte| out(0xe9, byte);
}

fn out(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port),
    );
}
