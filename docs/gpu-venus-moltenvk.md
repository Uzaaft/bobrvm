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

## ⚠ Host Vulkan driver: KosmicKrisp, not MoltenVK (corrected 2026-07-24)

The `startergo/virglrenderer` venus build targets **KosmicKrisp** — LunarG's
Mesa-based Vulkan-on-Metal driver (Vulkan 1.3 conformant, merged into Mesa 26.0,
Oct 2025; requires **Metal 4 → macOS 26+**, satisfied here on macOS 27). Evidence:
the dylib imports guest memory via `VK_EXT_external_memory_metal` /
`vkr_context_import_resource_metal`, and the tap README says "Venus support via
KosmicKrisp". MoltenVK does **not** expose Metal external memory, so venus can't
share resources through it: `virgl_renderer_init(VENUS|NO_VIRGL)` succeeds and
the Venus capset reports present, but `context_create_with_flags(capset=VENUS)`
returns **EINVAL (22)** against the MoltenVK ICD.

Consequence: the earlier `tools/mvk_probe.c` ceiling numbers were measured
against the *wrong* driver. The real Venus ceiling is **KosmicKrisp's** Vulkan
1.3 feature set (reported ~MoltenVK parity as of Mesa 26.0). Re-probe once
KosmicKrisp is installed.

**KosmicKrisp built** (Mesa 26.3-devel, `tools/`-style script in scratchpad):
`meson setup -Dplatforms=macos -Dvulkan-drivers=kosmickrisp -Dgallium-drivers=
-Dopengl=false -Dzstd=disabled -Dvideo-codecs= -Dllvm=enabled --prefer-static`.
Deps: `libclc` + `llvm` (KosmicKrisp forces `with_driver_using_cl` for its
precompiled shaders) + `spirv-llvm-translator` (must match LLVM major.minor:
22.1) + `spirv-tools`/`spirv-headers`. Produces `libvulkan_kosmickrisp.dylib` +
`kosmickrisp_mesa_icd.aarch64.json` (library_path `/opt/homebrew/lib/…`, so
symlink the built dylib there). **Measured ceiling** (`tools/mvk_probe.c` via the
loader with `VK_ICD_FILENAMES` = KK ICD): Vulkan **1.4**, tessellation, compute,
huge SSBO limits, `logicOp`/`shaderCullDistance`/`conditional_rendering`/
`multi_draw` (all better than MoltenVK); still no fp64/geometryShader/
`VK_EXT_transform_feedback` (Metal-fundamental → Zink lowers).

## ⛔ BLOCKER: Venus render-server transport is broken on macOS

Venus in this virglrenderer build runs in a **render-server subprocess**
(`virgl_render_server`), and that proxy sets up its control channel with
`socketpair(AF_UNIX, SOCK_SEQPACKET, …)`. **macOS has no `AF_UNIX`/`SOCK_SEQPACKET`**
→ `errno 43 EPROTONOSUPPORT` → `failed to initialize venus renderer`. In-process
venus (init without `RENDER_SERVER`) returns **EINVAL** at
`context_create_with_flags(VENUS)` — this build's venus is render-server-only.
Net: neither venus path works on macOS as shipped.

**Fix step 1 (DONE, works):** the tap's `virglrenderer-macos-unified.patch`
*already* implements length-prefixed framing for non-SEQPACKET sockets
(`render_context_socket_header`, `ntohl(hdr.length)`, gated on `is_seqpacket`)
but left the socket type as `SOCK_SEQPACKET` on the `__APPLE__` branch in **both**
`server/render_socket.c` **and** `src/proxy/proxy_socket.c`. Rebuilding
virglrenderer 1.3.0 from source with the tap's 20-patch stack plus both
`__APPLE__` branches → `SOCK_STREAM` (see `tools/build-virglrenderer-macos.sh`)
gets the render server to **fork and `virgl_renderer_init` to return 0**. Installs
to `scratchpad/virgl-fixed`.

**Fix step 2 (DONE, works):** the "worker jail" failure was a red herring — its
real cause was `create_sigchld_fd()` calling `fcntl(kq, F_SETFL, O_NONBLOCK)` on
a **kqueue fd**, which macOS rejects (kqueue is polled via `kevent()`, not
`read()`; reaping uses `waitid(WNOHANG)`). That -1 cascaded to "failed to create
worker jail". Dropping the fcntl block (`server/render_worker.c`, `__APPLE__`
path) fixes it. See `tools/build-virglrenderer-macos.sh` STAGE 3b.

**✅ RESULT: Venus context creation works end-to-end on macOS.** With both fixes,
`context_create_with_flags(VENUS)` returns 0 against the KosmicKrisp ICD in
render-server mode: guest Venus → virglrenderer (fixed) → forked
`virgl_render_server` (jail via kqueue) → KosmicKrisp → Metal. Init flags:
`VENUS | NO_VIRGL | RENDER_SERVER` (0x2C0), `RENDER_SERVER_EXEC_PATH` =
`virgl-fixed/libexec/virgl_render_server`.

Known follow-up (not yet blocking context create): a teardown-time
`virgl_render_server: failed to receive message: truncated or incomplete` log —
appears after the context is created+destroyed (likely a disconnect/EOF framing
edge on SOCK_STREAM); verify it doesn't bite real command submission.

## Remaining bridge work (bobrvm side)

The host stack is proven. Progress:
1. ✅ `venus.zig` render-server mode (`INIT_FLAGS` += `RENDER_SERVER`,
   `setRenderServerPath`); `build.zig` `-Dvirgl-prefix` → `~/.local/opt/virgl-macos`.
2. ✅ `src/virtio/gpu.zig` dispatch wired behind `-Dgpu-venus` (jj pending):
   advertises the Venus capset (index 2 / id 4, `num_capsets`→3, `F_CONTEXT_INIT`),
   fills it via `venus.Host.fillCaps`, and routes `CTX_CREATE`(context_init capset
   == venus) / `SUBMIT_3D` / `CTX_DESTROY` to `venus.Host` (tracking venus ctx_ids
   in a set). All comptime-gated on `gpu_venus`; the default build is byte-identical
   and does not link virglrenderer. Both `zig build` and `zig build -Dgpu-venus`
   compile; the venus `-Dgpu-venus` CLI links the fixed virglrenderer and is signed
   with `cli-venus.entitlements` (hypervisor + disable-library-validation).
   **Not runtime-tested** — needs a guest + HVF (sandbox blocks both). The
   `venus.Host` calls it makes are the same ones lldb-verified in `venus_smoke`.
3. ✅ Runtime env self-config: `venus.ensureHost()` sets `RENDER_SERVER_EXEC_PATH`
   + `VK_ICD_FILENAMES` from the build prefix (user env still wins). Only
   `DYLD_LIBRARY_PATH` must be set pre-launch (dyld reads it at exec).
4. TODO: present — map the venus output blob → IOSurface/Metal for scanout
   (needed to *see* the desktop; NOT needed for the glxinfo version proof).
5. TODO: verify real command submission + `glxinfo` ≥ 4.3 — user-machine handoff.

## Handoff: testing `glxinfo` ≥ 4.3 on a real machine

The version proof needs the Venus capset + context creation (both done), not the
present path. On a Mac with the built stack:

```
# 1. (re)build the macOS-patched virglrenderer + KosmicKrisp if needed:
tools/build-virglrenderer-macos.sh        # → ~/.local/opt/virgl-macos
tools/build-kosmickrisp.sh                # → KK dylib in /opt/homebrew/lib

# 2. build bobrvm with the venus backend:
zig build -Dgpu-venus

# 3. run with the vulkan-loader on DYLD path (the only env still required):
export DYLD_LIBRARY_PATH=/opt/homebrew/opt/vulkan-loader/lib:/opt/homebrew/opt/spirv-tools/lib:/opt/homebrew/opt/angle/lib:/opt/homebrew/lib
zig-out/bin/bobrvm --kernel <k> --gpu ...   # boot a guest whose Mesa has venus + zink

# 4. in the guest (needs kernel virtio-gpu + Mesa ≥ recent with venus & zink):
MESA_LOADER_DRIVER_OVERRIDE=zink GALLIUM_DRIVER=zink glxinfo | grep "OpenGL version"
```

If the bridge is correct this reports GL ≥ 4.3. Not yet run — no venus+zink guest
image on hand, and the CI sandbox blocks HVF.

## Host components

- `molten-vk` (Homebrew 1.4.1): `/opt/homebrew/opt/molten-vk/lib/libMoltenVK.dylib`.
- `vulkan-headers` (Homebrew): `/opt/homebrew/opt/vulkan-headers/include`.
- `virglrenderer` **with Venus enabled** (Homebrew tap
  `startergo/virglrenderer` 1.0.41, built `-Dvenus=true`; pulls
  `startergo/angle` + `startergo/libepoxy` + `startergo/gn`):
  `/opt/homebrew/opt/virglrenderer/{lib/libvirglrenderer.dylib,include/virgl/virglrenderer.h}`.
- `vulkan-loader` (Homebrew): `libvulkan.dylib`. virglrenderer's Venus backend
  `dlopen`s `libvulkan.dylib`, so the loader is required; it discovers MoltenVK
  via the ICD manifest at `/opt/homebrew/etc/vulkan/icd.d/MoltenVK_icd.json`.
- ANGLE (`libEGL`/`libGLESv2`) at `/opt/homebrew/opt/angle/lib` — only the
  legacy virgl-GL winsys uses it; the Venus path does not.
- Guest: Mesa with the `venus` Vulkan driver + `zink` GL driver; kernel with
  `virtio-gpu` + `VIRTIO_GPU_CAPSET_VENUS`. Guest env:
  `MESA_LOADER_DRIVER_OVERRIDE=zink`, `GALLIUM_DRIVER=zink`,
  and the venus ICD selected for Vulkan.

## Phased plan (loop executes top-down)

1. **Host Vulkan foundation** ✅ done: MoltenVK + headers installed; capability
   probe green (VkInstance, physical device, feature/extension enumeration).
2. **virglrenderer(venus) building + linked** ✅ done (host side proven).
   `tools/virgl_smoke.c` calls `virgl_renderer_init` and enumerates capsets.
   Result on M3 Max: init returns 0 and the **Venus capset (id 4, size 160)**
   is PRESENT (VIRGL/VIRGL2 also present). Key facts for the bridge:
   - Init flags **must** be `VIRGL_RENDERER_VENUS | VIRGL_RENDERER_NO_VIRGL`
     (0xC0; `THREAD_SYNC` 0x02 optional). `VENUS` alone fails with "invalid
     renderer vrend callbacks"; adding `USE_EGL` fails with "EGL is not
     supported on this platform" (the ANGLE/vrend GL winsys, which Venus skips).
   - Callbacks: `version = 1` with a non-NULL `write_fence` suffices to init.
   - Runtime env: `VK_ICD_FILENAMES=/opt/homebrew/etc/vulkan/icd.d/MoltenVK_icd.json`,
     and `DYLD_LIBRARY_PATH` must include angle, vulkan-loader, molten-vk,
     `/opt/homebrew/lib`.
   - **Codesigning**: an unsigned binary loading these dylibs is SIGKILLed by
     AMFI pre-`main` (runs fine under lldb via get-task-allow). The real bobrvm
     CLI is already codesigned; add `com.apple.security.cs.disable-library-validation`
     (and jit/unsigned-mem) to `cli.entitlements` when linking these in.
   - `build.zig` linkage done: `zig build venus-smoke` builds `tools/venus_smoke.zig`
     (imports `src/gpu/venus.zig`), links `-lvirglrenderer` with rpath, and
     codesigns with `venus.entitlements` (disable-library-validation + jit). The
     Zig↔virglrenderer FFI is verified: init OK, VENUS capset present.
   - **Sandbox caveat**: in a seatbelt-sandboxed shell the binary is SIGKILLed
     before `main` while virglrenderer's initializers run (affects the smoke
     test only in that shell — it is not a code-signing issue; ad-hoc dylibs +
     disable-library-validation do not change it). Run it under lldb there
     (`lldb -b -o run -o quit zig-out/bin/venus_smoke`); on a normal codesigned
     macOS session it runs directly. `venus.zig` stays isolated from the unit-test
     binary (not imported by `src/lib.zig`), so `zig build test` is unaffected.
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
