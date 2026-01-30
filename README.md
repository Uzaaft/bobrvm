Fuck you broadcom




# bobrvm

Linux virtualization for macOS with OpenGL 4.3 and Vulkan support.

## Features

- **OpenGL 4.3** via virgl → Metal translation
- **Vulkan 1.3** via Venus → Metal translation  
- **Apple Silicon native** using Hypervisor.framework
- **Zero-copy GPU** via IOSurface sharing
- **Fast file sharing** via virtiofs + DAX

## Requirements

- macOS 13+ (Ventura or later)
- Apple Silicon (M1/M2/M3/M4) or Intel Mac
- Nix package manager

## Building

```bash
# Enter development shell
nix develop

# Build release
nix build

# Build debug
nix build .#debug

# Run tests
nix build .#test
```

### Development with Zig

```bash
# Build library only
zig build

# Build macOS app
zig build -Demit-macos-app

# Build and run with terminal logging (dev mode)
zig build run
```

## Logging

bobrvm has dual logging: stderr (terminal) and macOS unified logging.

### Dev Mode

When running via `zig build run`, logs automatically appear in the terminal:

```
info: (main) bobrvm initialized (version 0.1.0)
debug: (apprt) creating app instance
info: (apprt) app created successfully
info: (renderer) starting renderer thread (target 60fps)
```

### Environment Variable

Control logging with `BOBRVM_LOG`:

```bash
# Enable all logging (stderr + macOS unified log)
BOBRVM_LOG=true ./Bobrvm.app/Contents/MacOS/Bobrvm

# Disable all logging
BOBRVM_LOG=false ./Bobrvm.app/Contents/MacOS/Bobrvm

# Fine-grained control
BOBRVM_LOG=stderr=true,macos=false ./Bobrvm.app/Contents/MacOS/Bobrvm
```

### macOS Unified Logging

View logs from deployed apps:

```bash
log stream --level debug --predicate 'subsystem=="com.bobrvm.lib"'
```

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Swift (UI only)                                    │
│  - NSWindow, CAMetalLayer                           │
│  - Routes input events to Zig                       │
└──────────────────┬──────────────────────────────────┘
                   │ C FFI (bobrvm.h)
                   ▼
┌─────────────────────────────────────────────────────┐
│  Zig Core (libbobrvm)                               │
│  - Hypervisor.framework bindings                    │
│  - virtio device emulation                          │
│  - virgl/Venus → Metal translation                  │
│  - Renderer thread (60fps)                          │
└─────────────────────────────────────────────────────┘
```

## Project Structure

```
bobrvm/
├── flake.nix           # Nix build
├── build.zig           # Zig build
├── include/bobrvm.h    # C API
├── src/
│   ├── apprt/          # Application runtime
│   ├── hypervisor/     # Hypervisor.framework
│   ├── virtio/         # Virtio devices
│   ├── gpu/            # GPU translation
│   └── renderer/       # Metal rendering
└── macos/              # Swift UI (future)
```

## License

MIT
