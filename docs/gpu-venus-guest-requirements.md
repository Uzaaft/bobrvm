# Venus guest requirements

A guest uses the upstream Mesa Venus Vulkan driver and Zink OpenGL driver.
bobrvm does not ship a guest GPU driver.

## Requirements

- AArch64 Linux with kernel `virtio-gpu` and Venus capset support.
- Mesa 25.2 or newer, built with `venus` and `zink`.
- Host-visible Venus blobs aligned to 16 KiB on Apple Silicon.

Mesa 25.0 has an ICD interface negotiation bug that can make Zink fail with
`VK_ERROR_INCOMPATIBLE_DRIVER`. Upgrade rather than working around it.

Apple Hypervisor.framework maps guest memory at 16 KiB granularity. Satisfy
that constraint in one of these ways:

1. Use a guest kernel built with `CONFIG_ARM64_16K_PAGES`.
2. Patch Mesa to round Venus host-visible blob allocations to `0x4000` in
   `virtgpu_shmem_create()` and `virtgpu_bo_create_from_device_memory()`.
3. Use `tools/venus_align_shim.c` for development and integration testing.

Prefer a 16 KiB guest kernel for maintained images. The preload shim is a test
aid, not a production guest interface. A prebuilt patched Debian/Ubuntu Mesa is
available from [osy's Venus setup notes][osy-venus].

## Runtime

Select the Venus ICD and Zink explicitly when the image does not make them the
default:

```sh
export VK_ICD_FILENAMES=<mesa>/share/vulkan/icd.d/virtio_icd.aarch64.json
export MESA_LOADER_DRIVER_OVERRIDE=zink
export GALLIUM_DRIVER=zink
```

For a headless EGL check, also set `EGL_PLATFORM=surfaceless`.

## Verification

1. Run `vulkaninfo`; it must list the virtio/Venus device.
2. Run `glxinfo`; the core profile must be at least OpenGL 4.3.
3. Run `tests/integration/gl/gltest-venus.sh` from the host.

The integration script uses `VENUS_GLTEST_MIN=4.3` by default. Set it to `2.1`
only when checking whether the transport stack starts.

If instance creation returns `VK_ERROR_INCOMPATIBLE_DRIVER`, check the guest
Mesa version. If blob mapping fails, check the guest page size or alignment
patch before debugging the host renderer.

## References

- [Mesa Venus](https://docs.mesa3d.org/drivers/venus.html)
- [Mesa Zink](https://docs.mesa3d.org/drivers/zink.html)
- [Linux arm64 page sizes](https://docs.kernel.org/arch/arm64/memory.html)

[osy-venus]: https://gist.github.com/osy/a8f705050eed1c8421ad1a0855a8faa9
