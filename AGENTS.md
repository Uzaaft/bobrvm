# bobrvm Agent Guidelines

Linux virtualization software for macOS with OpenGL 4.3 and Vulkan support.

## Quick Reference

```bash
# Build (Zig/Nix)
nix build                           # Release build (libbobrvm + headers)
nix build .#debug                   # Debug build
nix build .#xcframework             # Build BobrvmKit.xcframework
nix develop                         # Enter dev shell

# Build (Swift/Xcode) - NOT managed by Nix
open macos/Bobrvm.xcodeproj         # Open in Xcode
xcodebuild -scheme Bobrvm           # CLI build

# Test  
nix build .#test                    # Run all Zig tests
zig build test -Dtest-filter=<name> # Filter tests

# Format
zig fmt .                           # Zig code
alejandra .                         # Nix files
swift-format -i -r macos/           # Swift code

# Version Control (jj, not git)
jj status                           # Current status
jj diff                             # Show changes
jj new                              # Create new change
jj describe -m "type(scope): msg"   # Describe change
jj bookmark set main                # Update bookmark
```

## Stack

| Layer | Technology |
|-------|------------|
| Core | Zig (libbobrvm) |
| UI | Swift/SwiftUI + AppKit (window chrome only) |
| Rendering | Zig (Metal command encoding) |
| Build | Nix (Zig only) + Xcode (Swift only) |
| VCS | jj (Jujutsu) |
| Hypervisor | Apple Hypervisor.framework |
| Graphics | virgl/Venus → Metal |

### Rendering Ownership (Ghostty Pattern)

Swift owns the **window and Metal context**, Zig owns **all rendering**:

```
Swift                          Zig
─────                          ───
NSWindow                       
NSView + CAMetalLayer          
MTLDevice ──────────────────►  renderer.Thread
                               ├─ Metal command buffers
                               ├─ virgl/Venus translation
keyboard/mouse ─────────────►  ├─ input handling
                               └─ frame presentation
```

Swift responsibilities:
- Window lifecycle, menu bar, toolbar
- Create `CAMetalLayer`, `MTLDevice`, `MTLCommandQueue`
- Pass Metal pointers to Zig via C API
- Route input events to `bobrvm_vm_input()`
- Call `bobrvm_surface_draw()` on CVDisplayLink

Zig responsibilities:
- ALL Metal command encoding
- virgl/Venus → Metal translation
- Renderer thread (60fps loop)
- Frame presentation via `nextDrawable`
- GPU synchronization

### C API (Swift ↔ Zig Interface)

```c
// include/bobrvm.h

// Opaque handles
typedef void* bobrvm_app_t;
typedef void* bobrvm_vm_t;
typedef void* bobrvm_surface_t;
typedef void* bobrvm_config_t;

// App lifecycle
bobrvm_app_t bobrvm_app_new(const bobrvm_runtime_config_s* runtime_cfg);
void bobrvm_app_destroy(bobrvm_app_t app);
void bobrvm_app_tick(bobrvm_app_t app);  // Process pending events

// VM lifecycle
bobrvm_vm_t bobrvm_vm_new(bobrvm_app_t app, const bobrvm_vm_config_s* cfg);
void bobrvm_vm_destroy(bobrvm_vm_t vm);
void bobrvm_vm_start(bobrvm_vm_t vm);
void bobrvm_vm_stop(bobrvm_vm_t vm);
void bobrvm_vm_pause(bobrvm_vm_t vm);
void bobrvm_vm_resume(bobrvm_vm_t vm);

// Surface: Swift passes Metal context, Zig owns rendering
bobrvm_surface_t bobrvm_surface_new(
    bobrvm_vm_t vm,
    void* mtl_device,      // MTLDevice*
    void* mtl_layer,       // CAMetalLayer*
    void* mtl_queue        // MTLCommandQueue*
);
void bobrvm_surface_destroy(bobrvm_surface_t surface);
void bobrvm_surface_set_size(bobrvm_surface_t surface, uint32_t width, uint32_t height);
void bobrvm_surface_draw(bobrvm_surface_t surface);  // Called on CVDisplayLink

// Input: Swift routes events to Zig
void bobrvm_surface_key(bobrvm_surface_t surface, bobrvm_key_event_s event);
void bobrvm_surface_mouse_button(bobrvm_surface_t surface, bobrvm_mouse_button_e button, bool pressed);
void bobrvm_surface_mouse_pos(bobrvm_surface_t surface, double x, double y);
void bobrvm_surface_mouse_scroll(bobrvm_surface_t surface, double dx, double dy);

// Runtime callbacks (Zig → Swift)
typedef struct {
    void* userdata;
    void (*wakeup)(void* userdata);                    // Wake main thread
    void (*set_title)(void* userdata, const char* title);
    void (*request_close)(void* userdata);
    bool (*read_clipboard)(void* userdata, char** out_text);
    void (*write_clipboard)(void* userdata, const char* text);
} bobrvm_runtime_config_s;

// VM configuration
typedef struct {
    uint64_t memory_bytes;
    uint8_t vcpu_count;
    const char* kernel_path;
    const char* initrd_path;
    const char* cmdline;
    const char* disk_path;
} bobrvm_vm_config_s;

// Input events
typedef struct {
    uint32_t keycode;
    uint32_t modifiers;
    bool pressed;
} bobrvm_key_event_s;

typedef enum {
    BOBRVM_MOUSE_LEFT,
    BOBRVM_MOUSE_RIGHT,
    BOBRVM_MOUSE_MIDDLE,
} bobrvm_mouse_button_e;
```

## Project Structure

```
bobrvm/
├── flake.nix                 # Nix flake (build entry)
├── flake.lock
├── build.zig                 # Zig build (called by Nix)
├── build.zig.zon             # Zig dependencies
├── include/
│   └── bobrvm.h              # C API header (Swift FFI)
├── src/
│   ├── main.zig              # CLI entry (if standalone)
│   ├── main_c.zig            # C API exports for libbobrvm
│   ├── lib.zig               # Library root
│   ├── quirks.zig            # Optimization workarounds
│   ├── build/                # Build system modules
│   │   ├── main.zig
│   │   ├── Config.zig
│   │   ├── SharedDeps.zig
│   │   ├── BobrvmLib.zig
│   │   └── BobrvmXCFramework.zig
│   ├── apprt/                # Application runtime abstraction
│   │   ├── main.zig
│   │   └── embedded.zig      # macOS/Swift runtime
│   ├── hypervisor/           # Hypervisor.framework bindings
│   │   ├── main.zig
│   │   ├── vm.zig
│   │   └── vcpu.zig
│   ├── virtio/               # Virtio device implementations
│   │   ├── main.zig
│   │   ├── queue.zig
│   │   ├── console.zig
│   │   ├── gpu.zig
│   │   ├── fs.zig
│   │   └── input.zig
│   ├── gpu/                  # GPU translation layer
│   │   ├── main.zig
│   │   ├── virgl.zig         # OpenGL 4.3 command parsing
│   │   ├── venus.zig         # Vulkan command parsing
│   │   └── metal_backend.zig # Metal command encoding
│   └── renderer/             # Render thread
│       ├── main.zig
│       └── Thread.zig
├── macos/                    # Swift/Xcode project (NOT managed by Nix)
│   ├── Bobrvm.xcodeproj/
│   ├── Sources/
│   │   ├── App/
│   │   │   ├── AppDelegate.swift
│   │   │   └── BobrvmApp.swift
│   │   └── Bobrvm/
│   │       ├── VMSurfaceView.swift
│   │       ├── VMManager.swift
│   │       └── Config.swift
│   └── BobrvmKit.xcframework/  # Copy from zig-out/ after `nix build .#xcframework`
└── pkg/                      # Vendored C dependencies
    └── ...
```

## Coding Style

We follow **TigerBeetle's TIGER_STYLE** and **Ghostty's patterns**.

### Core Philosophy

**Priority order: Safety → Performance → Developer Experience**

### Zig Conventions

#### Module Structure

```zig
//! VMSurface manages a single virtualized display surface.
//! It owns the renderer thread and coordinates with the virtio-gpu device.
const VMSurface = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = @import("quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;

// Local imports after stdlib
const virtio = @import("virtio/main.zig");
const renderer = @import("renderer/main.zig");
```

#### Assertions (Minimum 2 per function)

```zig
pub fn submitFrame(self: *VMSurface, buffer: *const FrameBuffer) !void {
    // Pre-conditions
    assert(self.state == .running);
    assert(buffer.width > 0 and buffer.height > 0);
    assert(buffer.format == .bgra8888);
    
    // ... implementation ...
    
    // Post-conditions
    assert(self.pending_frames.items.len <= max_pending_frames);
}
```

#### Error Handling

```zig
pub const CreateError = Allocator.Error || HypervisorError;
pub const InitError = error{
    VmCreationFailed,
    MemoryMapFailed,
    VcpuCreationFailed,
};

pub fn create(alloc: Allocator) CreateError!*VM {
    var vm = try alloc.create(VM);
    errdefer alloc.destroy(vm);
    try vm.init(alloc);
    return vm;
}
```

#### Memory Management

```zig
// All memory statically allocated at startup
pub fn init(self: *VM, alloc: Allocator) !void {
    self.alloc = alloc;
    self.vcpus = try alloc.alloc(Vcpu, max_vcpus);
    errdefer alloc.free(self.vcpus);
    // ...
}

pub fn deinit(self: *VM) void {
    for (self.vcpus) |*vcpu| vcpu.deinit();
    self.alloc.free(self.vcpus);
}

pub fn destroy(self: *VM) void {
    self.deinit();
    self.alloc.destroy(self);
}
```

#### Naming

```zig
// Units LAST, sorted by descending significance
const latency_ns_max: u64 = 16_000_000;  // 16ms
const latency_ns_min: u64 = 1_000_000;   // 1ms

// Matching lengths for alignment
var source: []const u8 = undefined;
var target: []u8 = undefined;
var source_offset: usize = 0;
var target_offset: usize = 0;

// Nouns over adjectives
vm.display    // not: vm.displaying
vcpu.running  // exception for state bools

// Helper function prefix
fn read_memory(self: *VM, addr: u64) !u64 { ... }
fn read_memory_callback(self: *VM, result: ReadResult) void { ... }
```

#### Control Flow

```zig
// Hard limit: 70 lines per function
// Push ifs up, fors down
// No recursion

// Explicit bounds on everything
for (queue.items[0..@min(queue.items.len, max_batch)]) |item| {
    try self.processItem(item);
}

// Single-line if for assertions
if (index >= len) assert(false);

// Braces unless single line
if (condition) return early;

if (complex_condition) {
    doThing();
}
```

#### Struct Field Order

```zig
const VMConfig = struct {
    // Fields first
    memory_bytes: u64,
    vcpu_count: u8,
    display_width: u32,
    display_height: u32,
    
    // Nested types
    const DisplayMode = enum { windowed, fullscreen };
    const Self = @This();
    
    // Methods last
    pub fn validate(self: Self) !void { ... }
};
```

### Swift Conventions

```swift
// Type-safe wrappers around C API
extension Bobrvm {
    @MainActor
    final class VM: ObservableObject {
        @Published private(set) var state: VMState = .stopped
        private var handle: bobrvm_vm_t?
        
        init(config: VMConfig) throws {
            var cConfig = config.toCConfig()
            guard let h = bobrvm_vm_new(&cConfig) else {
                throw VMError.creationFailed
            }
            self.handle = h
        }
        
        deinit {
            if let h = handle {
                bobrvm_vm_destroy(h)
            }
        }
    }
}
```

### Formatting

| Check | Command |
|-------|---------|
| Zig | `zig fmt --check .` |
| Nix | `alejandra --check .` |
| Swift | `swift-format lint -r macos/Sources` |

- 100 column hard limit
- 4-space indentation (Zig default)
- Run formatters before commit

## Commits (jj)

Use conventional commits:

```
type(scope): short description

- feat: new feature
- fix: bug fix
- perf: performance improvement
- refactor: code restructure
- docs: documentation
- test: test changes
- build: build system
- chore: maintenance
```

Examples:
```bash
jj describe -m "feat(virtio-gpu): implement virgl command parsing"
jj describe -m "fix(hypervisor): correct memory region alignment"
jj describe -m "perf(renderer): batch Metal command encoding"
```

**Commit frequently. Small, focused changes.**

## Build System

### Nix Flake Structure

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig.url = "github:mitchellh/zig-overlay";
    flake-utils.url = "github:numtide/flake-utils";
  };
  
  outputs = { self, nixpkgs, zig, flake-utils }:
    flake-utils.lib.eachSystem [ "aarch64-darwin" "x86_64-darwin" ] (system: {
      packages.default = ...;
      packages.debug = ...;
      packages.test = ...;
      packages.xcframework = ...;
      devShells.default = ...;
    });
}
```

### Zig Build Integration

Nix calls `zig build` with appropriate flags. Keep `build.zig` modular:

```zig
// build.zig
const buildpkg = @import("src/build/main.zig");

pub fn build(b: *std.Build) !void {
    const config = try buildpkg.Config.init(b);
    const deps = try buildpkg.SharedDeps.init(b, &config);
    const lib = try buildpkg.BobrvmLib.init(b, &config, &deps);
    // ...
}
```

## Testing

```bash
# Run all Zig tests
nix build .#test

# Filter specific tests
zig build test -Dtest-filter="virtio"

# Run with debug output
zig build test -Dlog-level=debug
```

Test patterns:
```zig
test "virtqueue ring buffer wraps correctly" {
    var queue = try VirtQueue.init(testing.allocator, 16);
    defer queue.deinit();
    
    // Fill to capacity
    for (0..16) |i| {
        try queue.push(@intCast(i));
    }
    
    // Verify wrap
    try testing.expectEqual(@as(u16, 0), queue.head);
    try testing.expectEqual(@as(u16, 16), queue.tail);
}
```

## Performance Guidelines

1. **Design for performance first** — back-of-envelope calculations before coding
2. **Batch operations** — minimize host↔guest transitions
3. **Zero-copy where possible** — IOSurface for textures, shared memory for buffers
4. **Hot path extraction** — isolate performance-critical code in small functions
5. **No allocations in hot paths** — pre-allocate everything at init

## Security

- No secrets in code or commits
- Validate all guest inputs (virtio commands)
- Sandbox renderer thread
- Use `assert` liberally for invariants

## Dependencies

**Zero external runtime dependencies** (apart from system frameworks).

Vendored C libraries go in `pkg/`. Prefer Zig reimplementations where feasible.

## Boot Architecture

### UEFI Boot vs Direct Linux Boot

**UEFI firmware (QEMU_EFI.fd) requires PCI devices, not virtio-mmio:**
- ARM virt machines moved from virtio-mmio to virtio-pci years ago
- UEFI has no drivers for virtio-mmio; it expects PCI devices
- DTB `virtio,mmio` nodes are for Linux direct boot only
- UEFI enumerates PCI ECAM (0x3c000000-0x40000000) looking for devices

**Two boot paths:**
1. **Direct Linux boot**: Load kernel at 0x40200000, DTB in x0, use virtio-mmio
2. **UEFI boot**: Requires PCIe ECAM host bridge + virtio-pci devices

**Memory Map (QEMU virt compatible):**
| Region | Address | Size |
|--------|---------|------|
| Flash (firmware) | 0x00000000 | 64MB |
| Flash (vars) | 0x04000000 | 64MB |
| GIC Distributor | 0x08000000 | 64KB |
| GIC Redistributor | 0x080A0000 | 128KB/CPU |
| UART (PL011) | 0x09000000 | 4KB |
| Virtio MMIO | 0x0A000000 | 512B/device |
| PCI MMIO | 0x10000000 | 768MB |
| PCI ECAM | 0x3C000000 | 64MB |
| RAM | 0x40000000 | configurable |

## Links

- [TigerBeetle TIGER_STYLE](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md)
- [Ghostty Architecture](https://github.com/ghostty-org/ghostty)
- [Apple Hypervisor.framework](https://developer.apple.com/documentation/hypervisor)
- [virtio-gpu spec](https://docs.oasis-open.org/virtio/virtio/v1.2/virtio-v1.2.html)
