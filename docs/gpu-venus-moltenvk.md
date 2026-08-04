# Venus host stack

The filename is retained for existing links. The active Vulkan-on-Metal driver
is KosmicKrisp, not MoltenVK.

## Architecture

```
guest Zink/Venus
  → bobrvm virtio-gpu
  → virglrenderer Venus decoder
  → virgl render server
  → KosmicKrisp
  → Metal
```

bobrvm owns virtio-gpu commands, blob mappings, fences, and scanout. It passes
Vulkan protocol work to upstream virglrenderer. The render server runs out of
process and is started with `posix_spawn` on macOS; do not replace this with a
post-Metal `fork()` path.

The Venus backend is opt-in so the default binary does not link the host GPU
stack.

## Host requirements

- Apple Silicon and macOS 26 or newer.
- Upstream virglrenderer with Venus and process render-server support.
- The bobrvm host-pointer shared-memory import patch from
  `third_party/patches/virglrenderer/0001-vkr-host-pointer-shm-import.patch`
  until an equivalent is upstream.
- KosmicKrisp and its Vulkan ICD manifest.
- The Vulkan loader and KosmicKrisp runtime libraries.

Use the repository scripts to install compatible components:

```sh
tools/build-virglrenderer-macos.sh
tools/build-kosmickrisp.sh
zig build -Dgpu-venus
```

Override the virglrenderer install location with
`-Dvirgl-prefix=<prefix>`. `src/gpu/venus.zig` derives the render-server and ICD
paths from the configured prefix unless the user has already set them.

`DYLD_LIBRARY_PATH` must be correct before launching bobrvm because dyld reads
it at process startup.

## Runtime contract

virglrenderer is initialized with:

```
VENUS | NO_VIRGL | RENDER_SERVER
```

Do not add EGL flags to the Venus-only path. The legacy virgl renderer and its
ANGLE dependencies are separate from this backend.

Guest-visible blobs must remain shared with the render server. The current
virglrenderer patch imports their host pointers through
`VK_EXT_external_memory_host`, avoiding a copy. Apple Silicon also requires the
guest-side 16 KiB alignment described in
[gpu-venus-guest-requirements.md](gpu-venus-guest-requirements.md).

## Verification

Use the small host probes before booting a guest:

- `tools/host_vk_probe.c` checks Vulkan instance and device creation.
- `tools/host_vk_mem_probe.m` checks the external-memory path.
- `venus-smoke` checks virglrenderer initialization and Venus context creation.

Then run `tests/integration/gl/gltest-venus.sh`. A successful result must cover
real rendering and readback through the complete stack, not only capability
enumeration.

When diagnosing startup failures, check dynamic-library loading and signatures
before the protocol. A missing KosmicKrisp dependency may appear as “no
drivers,” and macOS may terminate a process that loads an invalidly signed
dylib.

## Constraints

- Metal lacks native geometry shaders, transform feedback, and fp64. Zink and
  the Mesa compiler stack must lower or emulate them.
- Keep capability claims tied to integration or conformance tests.
- Keep local Mesa and virglrenderer patches isolated and removable.
- Presentation should preserve shared-memory/IOSurface paths; do not add a
  frame copy to simplify bring-up.

## References

- [Mesa Venus](https://docs.mesa3d.org/drivers/venus.html)
- [Mesa Zink](https://docs.mesa3d.org/drivers/zink.html)
- [virglrenderer](https://gitlab.freedesktop.org/virgl/virglrenderer)
- [Vulkan external memory host extension][external-memory-host]

[external-memory-host]: https://registry.khronos.org/vulkan/specs/latest/man/html/VK_EXT_external_memory_host.html
