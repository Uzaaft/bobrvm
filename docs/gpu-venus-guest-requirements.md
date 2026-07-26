# Venus GPU acceleration — guest requirements

How to get real Vulkan (and OpenGL 4.3 via Zink) inside a bobrvm guest on Apple
Silicon, using the `-Dgpu-venus` backend.

## The model (and what we do *not* ship)

bobrvm does **not** write or ship a proprietary guest GPU driver. Neither does
VMware Fusion or UTM — the guest always runs **upstream Mesa**; the custom part
lives on the host.

| Product | Guest driver (upstream Mesa) | Host translation |
|---|---|---|
| VMware Fusion | `vmwgfx` (kernel) + Mesa **svga** | SVGA3D → Metal (VMware, proprietary) |
| UTM | Mesa **virgl** / **venus** | virglrenderer → ANGLE / KosmicKrisp → Metal |
| **bobrvm** | Mesa **venus** | virglrenderer(venus) → **KosmicKrisp** → Metal |

So "how do we ship a driver?" is the wrong question. Like UTM's venus path, we
ship **guidance** (this document) plus a small, well-defined set of requirements
on the guest's Mesa. This mirrors what VMware Tools packaging does, minus the
proprietary driver.

## Host prerequisites (set up once)

- macOS 26+ (Metal 4) on Apple Silicon.
- Build bobrvm with venus: `zig build -Dgpu-venus`.
- Patched virglrenderer installed at `~/.local/opt/virgl-macos`
  (`tools/build-virglrenderer-macos.sh`).
- KosmicKrisp ICD built + installed (`tools/build-kosmickrisp.sh`) and a Vulkan
  loader (`brew install vulkan-loader`).
- Launch the VM with `--virgl` so the venus capset is advertised.

See `docs/gpu-venus-moltenvk.md` for the full host architecture.

## Guest requirements (two, both on the guest's Mesa venus driver)

### 1. Mesa venus ≥ 25.2.x

Mesa **25.0.x has a venus ICD interface-version bug**: `vn_CreateInstance`
returns `VK_ERROR_INCOMPATIBLE_DRIVER` even with a modern Vulkan loader. The ICD
negotiates loader-interface ≥ 5 with the loader (so the loader does *not* clamp
the requested API version to 1.0), but the driver's own
`vk_get_negotiated_icd_version()` reads `< 5` and then rejects any ≥ 1.1 instance
(`vn_icd_supports_api_version()`). Zink requests ≥ 1.1, so it fails.

Symptom in the host log / loader debug:

```
terminator_CreateInstance: Received return code -9 (VK_ERROR_INCOMPATIBLE_DRIVER)
from .../libvulkan_virtio.so. Skipping this driver.
MESA: error: ZINK: vkCreateInstance failed (VK_ERROR_INCOMPATIBLE_DRIVER)
```

Fixed upstream by Mesa 25.2.x. **Use a guest with Mesa ≥ 25.2** (Ubuntu 25.10,
recent Arch/Fedora, etc.) or override Mesa in your image.

### 2. The 16 KiB host-visible blob-alignment patch

Apple's Hypervisor.framework maps guest memory at **16 KiB** granularity. A
4 KiB-page guest packs venus's *host-visible* blobs (the command ring and reply
shmems) at 4 KiB offsets in the shared window, so the host cannot `hv_vm_map`
them (a non-16 KiB-aligned offset fails, and one 16 KiB host page can't back two
distinct 4 KiB guest allocations). This is **necessarily a guest-side fix** —
there is no host-side workaround.

Two ways to satisfy it:

- **Patch Mesa (UTM/osy's approach).** Round host-visible blob sizes up to
  16 KiB in the guest venus driver so `drm_mm` packs them at 16 KiB-aligned
  offsets. In `src/virtio/vulkan/vn_renderer_virtgpu.c`, in both
  `virtgpu_shmem_create()` and `virtgpu_bo_create_from_device_memory()`:

  ```c
  size = align64(size, 0x4000);   /* host 16 KiB pages */
  ```

  (One `size` variable feeds both `RESOURCE_CREATE_BLOB` and the subsequent
  `mmap`, so the kernel's `vm_size == vram_node.size` check stays consistent.)
  This patch is **not upstream** — it is a deliberate hack for 16 KiB hosts.

- **Or use a 16 KiB-page guest kernel** (`CONFIG_ARM64_16K_PAGES`). Then
  `PAGE_ALIGN` rounds blobs to 16 KiB naturally and no Mesa patch is needed.
  (Asahi Linux ships 16 KiB pages; this is the more "native" Apple-Silicon
  choice.)

## Recommended guest setups (easiest first)

1. **Prebuilt patched Mesa on Debian/Ubuntu (no building).** UTM's author ships
   `mesa-vulkan-drivers` / `mesa-libgallium` debs (Mesa 25.2.3 with both patches
   above) — install them directly on an aarch64 Debian/Ubuntu guest:
   <https://gist.github.com/osy/a8f705050eed1c8421ad1a0855a8faa9>
2. **16 KiB-page distro + stock recent Mesa.** Any guest with a
   `CONFIG_ARM64_16K_PAGES` kernel and Mesa ≥ 25.2 needs *only* requirement #1
   (the version) — the blob patch is unnecessary.
3. **Build your own.** Apply the 16 KiB patch to Mesa ≥ 25.2 for aarch64 and
   install the resulting `libvulkan_virtio.so`. For NixOS, a nixpkgs overlay
   bumping Mesa + applying the patch, then rebuilding the closure.

## Guest runtime environment (OpenGL via Zink over venus)

```sh
export VK_ICD_FILENAMES=<mesa>/share/vulkan/icd.d/virtio_icd.aarch64.json
export MESA_LOADER_DRIVER_OVERRIDE=zink
export GALLIUM_DRIVER=zink
# headless check without a display:
export EGL_PLATFORM=surfaceless
```

## Verifying

- `vulkaninfo` → a KosmicKrisp-backed device is present.
- `glxinfo | grep "OpenGL core profile version"` → **≥ 4.3**.
- Host log shows `venus GPU backend active`, `venus ctx_create`, and
  `create_blob` / `map_blob` lines with the blobs mapping successfully.

## Status / provenance

The bobrvm side of this path is complete and verified: with the requirements
above satisfied, the venus command ring maps, the protocol negotiates, and the
host KosmicKrisp reports Vulkan 1.4.350. The two virtio-gpu fixes that made this
work (the `RESP_OK_MAP_INFO` enum correction and venus blob-unref routing) are on
the `venus-mmap-fix` branch. The only remaining gap to a reported GL 4.3 number
is having a guest Mesa that meets requirements #1 and #2 — which is guest-image
configuration, not a bobrvm change.
