# GPU rearchitecture: Venus + MoltenVK (the path to real GL 4.3)

Status: **adopted** (2026-07-24). Supersedes the hand-rolled virgl→Metal
TGSI-to-MSL translator (`src/gpu/virgl/`) as the strategy for high OpenGL
versions. The old translator stays in-tree as a fallback until the new path
boots a desktop, then is retired.

## Why we pivoted

bobrvm needs OpenGL 4.3 in the guest to be a daily driver. The renderer we had
been building — guest Mesa `virgl` → TGSI → our Metal shader translator —
**cannot reach it**, and the reason is structural, not effort:

- The virgl GL backend only reaches GL 4.3 when the *host* has a real GL 4.3
  driver to forward to. On macOS the host has no such thing: Apple's OpenGL is
  frozen at 4.1 and deprecated, and Metal is not OpenGL. We were effectively
  reimplementing all of virglrenderer *and* a GL 4.3 driver on top of Metal, by
  hand, in Zig.
- The features that gate GL ≥3.2/4.0 (geometry shaders, fp64, transform
  feedback) have no native Metal equivalent, so hand-rolling them means writing
  the software-lowering passes ourselves.

VMware Fusion solves this with a *proprietary* in-house guest GL driver plus its
own host translation to Metal — the same shape of work, done at industrial
scale behind closed doors. The open-source equivalent, which the whole
ecosystem (Collabora, QEMU, UTM) converged on, is:

```
guest GL app
  → Zink            (Mesa: OpenGL → Vulkan; implements up to GL 4.6)
  → Venus           (virtio-gpu transport: guest Vulkan → host, SPIR-V passthrough)
  → virglrenderer   (host: Venus decoder → host Vulkan calls)
  → MoltenVK        (Vulkan → Metal)
  → Metal           (Apple GPU)
```

The win: we stop hand-writing GL translation. Zink is Mesa's mature GL-on-Vulkan
driver; MoltenVK is a mature Vulkan-on-Metal layer; Venus is a thin transport.
bobrvm's remaining job is the **host bridge**: wire virtio-gpu to
`virgl_renderer_*`, plumb blob/shared-memory resources and fences, and present
the result through the existing IOSurface zero-copy scanout.

## Empirical ceiling on this hardware (measured, not assumed)

Probe: link `libMoltenVK.dylib` directly, enumerate the physical device.
**Apple M3 Max, MoltenVK 1.4.1, Vulkan 1.3.334** (reproduce with `tools/mvk_probe.c`:
`clang -I/opt/homebrew/opt/vulkan-headers/include tools/mvk_probe.c -o /tmp/mvk_probe
-L/opt/homebrew/opt/molten-vk/lib -lMoltenVK -rpath /opt/homebrew/opt/molten-vk/lib && /tmp/mvk_probe`):

Present (Zink builds GL 4.3 on these):
- Vulkan 1.3, tessellation shaders, compute (32 KiB shared mem, 1024
  invocations), SSBOs (31/stage), `multiDrawIndirect` + first-instance,
  descriptor indexing, `VK_KHR_dynamic_rendering`, `create_renderpass2`,
  `imageCubeArray`, 8 color attachments, dual-source + independent blend,
  precise occlusion queries, `shaderInt64`, `maxImageDimension2D` 16384,
  `vertex_attribute_divisor`, `line_rasterization`, `shader_viewport_index_layer`.

Metal-fundamental gaps (identical walls whichever renderer we build):
- `shaderFloat64` = **0** — Metal has no doubles; true fp64 unavailable.
- `geometryShader` = **0** — Metal has no geometry-shader stage.
- `VK_EXT_transform_feedback` = **missing** on this MoltenVK build.

Why the pivot still reaches a usable GL 4.3 despite those gaps: **Mesa/Zink
lowers them in software** — `softfp64` (NIR fp64 emulation), geometry-shader
emulation, and transform-feedback emulation — down to the Vulkan feature set
MoltenVK does expose. These are exactly the passes we would otherwise have to
write and maintain ourselves. Caveat to stay honest about: fp64/GS/TF-heavy
apps run slow (software paths) or degrade; the common desktop/GTK/Qt/compositing
workload does not lean on them and runs on native features.

## Host components

- `molten-vk` (Homebrew 1.4.1): `/opt/homebrew/opt/molten-vk/lib/libMoltenVK.dylib`.
- `vulkan-headers` (Homebrew): `/opt/homebrew/opt/vulkan-headers/include`.
- `virglrenderer` **with Venus enabled** — not yet built on this machine. Must
  be built with `-Dvenus=true` against MoltenVK (a macOS + Venus tap exists:
  `startergo/homebrew-virglrenderer`). This is the next milestone's gating task.
- Guest: Mesa with the `venus` Vulkan driver + `zink` GL driver; kernel with
  `virtio-gpu` + `VIRTIO_GPU_CAPSET_VENUS`. Guest env:
  `MESA_LOADER_DRIVER_OVERRIDE=zink`, `GALLIUM_DRIVER=zink`,
  and the venus ICD selected for Vulkan.

## Phased plan (loop executes top-down)

1. **Host Vulkan foundation** ✅ done: MoltenVK + headers installed; capability
   probe green (VkInstance, physical device, feature/extension enumeration).
2. **virglrenderer(venus) building + linked** — get a venus-enabled
   virglrenderer dylib on macOS/MoltenVK; link it into `build.zig`; smoke-test
   `virgl_renderer_init` + capset enumeration reports the venus capset.
3. **virtio-gpu ↔ virglrenderer bridge** — route `CTX_CREATE` (venus capset),
   `SUBMIT_3D`, `RESOURCE_CREATE_BLOB`, `RESOURCE_MAP_BLOB`, and fences into the
   `virgl_renderer_*` C API from `src/virtio/gpu.zig` / `src/gpu/`. Keep the 2D
   scanout path.
4. **Blob resources + present** — map virgl's output resource to an IOSurface /
   `MTLTexture` for the existing zero-copy scanout; wire fence signalling into
   the device's used-buffer IRQ path.
5. **Guest bring-up** — a NixOS guest image with Mesa venus+zink; `glxinfo`
   reports GL ≥4.3; verify with the event-driven `gltest.sh` harness.
6. **Retire** the hand-rolled `src/gpu/virgl/` translator once Zink boots a
   desktop; keep it behind a `--gpu-legacy` flag for one release.

## Verification discipline (unchanged)

Every claim is backed by something that runs: probes for host features, MSL/
SPIR-V compile checks where relevant, and live `glxinfo`/`gltest.sh` against
real Mesa in the guest for the version headline. No advertising a capability the
stack does not actually honor.
