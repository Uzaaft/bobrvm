# GPU direction decision — Venus stack (2026-07-28)

**Status: adopted.** This supersedes the six July-26 custom-translator proposals
(`gpu-gl46-custom-translator-proposal.md`, `gpu-graphics-architecture-proposal.md`,
`gpu-custom-render-pipeline-architecture.md`, `gpu-full-graphics-architecture-pattern.md`,
`gl46-rendering-architecture-pattern.md`, `gpu-rendering-architecture-contract.md`),
which are preserved on the `gl46-experiment` change together with the
`src/gpu/gl46/` code, and resolves the conflict with `gpu-venus-moltenvk.md`
(also adopted — this doc updates its host-stack details).

## The decision

Guest OpenGL is delivered by the existing open stack:

```
guest GL app → Zink (GL→Vulkan, Mesa) → Venus (virtio-gpu Vulkan transport)
  → bobrvm virtio-gpu → upstream virglrenderer → KosmicKrisp (Vulkan→Metal) → Metal
```

The in-repo TGSI→Metal translator (`src/gpu/virgl/`) stays as the legacy/fallback
path for guests without venus+zink userspace; its honest capability level is
GL 2.x reported / GL 3.1 features. It is not the road to GL 4.x.

## Why

1. **Metal-fundamental gaps decide it.** Metal has no transform feedback, no
   geometry shaders, no fp64. The GL version gates require them. Mesa/Zink
   carries mature software lowerings for all three; a custom translator would
   have to reimplement them from scratch. Our own translator arc proved this
   wall empirically: reported version stuck at GL 2.0 behind TF/queries/MSAA,
   each a backend redesign, before 4.x work could even start.
2. **Nobody has shipped guest GL > 4.3 on a macOS host** (VMware Fusion: 4.3,
   proprietary, industrial scale; Parallels: 4.1; UTM beta: 4.1 + Vulkan 1.3
   via venus). The only demonstrated GL 4.6 on Metal anywhere is
   Zink-over-KosmicKrisp. If bobrvm wants the highest guest GL, this is the
   only credible route — and it beats every shipping competitor.
3. **The plumbing became upstream commodity in 2026.** virglrenderer merged
   native macOS support (build: MR !1600, posix_spawn workers: !1601, Metal
   shared memory emulating `VK_KHR_external_memory_fd` toward the guest:
   !1602, Metal device export: !1635). Our entire local patch stack
   (SEQPACKET→STREAM, kqueue fcntl, recvmsg framing, in-process
   `venus_inproc.c`) is obsolete; upstream builds unpatched on macOS and
   passes our venus-smoke. LunarG actively invests in KosmicKrisp (Vulkan 1.4
   CTS-conformant as of Mesa 26.2, July 2026).
4. **Where bobrvm differentiates on performance** is the hypervisor, not GL
   semantics: native HVF (no QEMU), zero-copy IOSurface present, lean virtio.

## Host stack (current)

- virglrenderer: upstream `main`, built unpatched →
  `~/.local/opt/virgl-upstream` (meson: `-Dplatforms= -Dvenus=true
  -Dvulkan-dload=true -Drender-server-worker=process`).
- KosmicKrisp ICD: `/opt/homebrew/lib/libvulkan_kosmickrisp.dylib`, json at
  `<prefix>/share/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json`.
- `src/gpu/venus.zig` INIT_FLAGS = `VENUS | NO_VIRGL | RENDER_SERVER`
  (workers are posix_spawn'd on macOS; Metal survives, unlike fork()).

## Status (2026-07-28): the full stack works end-to-end

The guest reports, through the complete chain
(zink → venus → bobrvm → virglrenderer → KosmicKrisp → Metal):

```
OpenGL compatibility profile renderer: zink Vulkan 1.4(Virtio-GPU Venus (Apple M3 Max) (MESA_KOSMICKRISP))
OpenGL compatibility profile version: 2.1 Mesa 26.1.5
```

Two host-side blockers were root-caused with probe binaries
(`tools/host_vk_probe.c`, `tools/host_vk_mem_probe.m` — seconds instead of
5-minute guest boots):

1. A brew cleanup had removed `spirv-tools`, so the KosmicKrisp dylib failed
   dlopen and the loader reported "Found no drivers" — the guest saw
   `VK_ERROR_INCOMPATIBLE_DRIVER`. (This also retroactively explains the
   earlier "enumerate failure" saga.)
2. vkr's Metal shared-memory allocator needs `VK_EXT_metal_objects` +
   MTLBUFFER import; KosmicKrisp has neither, and MoltenVK (which has both)
   reports robustness2 `nullDescriptor=0`, which zink hard-requires — so no
   stock pairing could run zink. Bridge: our virglrenderer patch
   (`tools/patches/virglrenderer-0001-vkr-host-pointer-shm-import.patch`)
   adds a `VK_EXT_external_memory_host` host-pointer import fallback;
   KosmicKrisp imports the shm zero-copy (vkMapMemory returns the shm
   pointer itself). Upstream-worthy.

**Version achieved (2026-07-28, vendored fork): GL 4.6 Core + Compat,
GLSL 4.60, OpenGL ES 3.2** — `VENUS-GLTEST: PASS (GL 4.6 >= 4.3)`. The four
zink gates were implemented in the vendored KosmicKrisp fork
(`third_party/patches/mesa/0001..0004`), each with real render/readback
tests, no capability-faking:

1. `VK_EXT_depth_clip_enable` (0001) — Metal single clip-or-clamp mapping.
2. `geometryShader` (0002) — Mesa's `poly` compute-geometry library wired
   into KK (honeykrisp pattern): 4-variant GS compile, sw-VS + GS compute
   prepasses, heap indirect draws, adjacency. Proof: GS-amplified triangle,
   4096/4096 pixels exact.
3. `VK_EXT_transform_feedback` (0003) — passthrough-GS synthesis for
   VS-only pipelines (the GL TF path), Bind/Begin/End + DrawIndirectByteCount
   + TF queries. Proof: exact-float capture readback.
4. RGB32 uniform texel buffers (0004) — NIR raw-load lowering (Metal lacks
   96-bit formats). Proof: exact texelFetch values + OOB robustness.

Drop these patches as LunarG lands equivalents upstream (their geometry
pipeline is visibly in flight — see README MR list). Known gaps documented
in the patch series: no XFB on tessellation pipelines, pipeline-statistics
queries unsupported, multistream >0 untested, no storage texel
buffers/atomics for RGB32. Correctness breadth beyond the targeted tests
(CTS/piglit sweeps) is future work.

`tests/integration/gl/gltest-venus.sh` gates on `VENUS_GLTEST_MIN`
(default 4.3 = the goal; 2.1 = today's stack-works regression floor).

## Guest requirements (see gpu-venus-guest-requirements.md)

- Mesa ≥ 25.2 venus driver (25.0.x has the vn_icd interface-version bug →
  `VK_ERROR_INCOMPATIBLE_DRIVER` at vkCreateInstance).
- 16KiB host-visible blob alignment on Apple Silicon: either a 16KiB-page
  guest kernel, a patched guest Mesa (UTM's approach), or the LD_PRELOAD shim
  `tools/venus_align_shim.c` (baked into `gl-mesa26.squashfs` at `/shim/`).
- Harness: `tests/integration/gl/gltest-venus.sh` with
  `GL_ASSETS=~/.local/share/bobrvm-gl` (uses `gl-mesa26.squashfs`,
  Mesa 26.1.5 closure).
