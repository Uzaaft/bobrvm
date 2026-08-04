# GPU direction: Venus and Zink

Status: adopted.

## Decision

Use the upstream Mesa stack for accelerated guest graphics:

```
guest OpenGL → Zink → Venus → virtio-gpu → virglrenderer
  → KosmicKrisp → Metal
```

The in-tree TGSI-to-Metal renderer remains a compatibility path. Do not extend
it to pursue OpenGL 4.x.

## Rationale

Metal does not expose transform feedback, geometry shaders, or native fp64.
Implementing OpenGL 4.x directly on Metal would require maintaining those
lowerings and the surrounding GL semantics. Mesa already provides the relevant
translation and emulation in Zink and its compiler stack.

bobrvm should own the VM boundary: virtio-gpu transport, memory sharing,
synchronization, and presentation. It should not own another OpenGL compiler.

The host Vulkan driver is KosmicKrisp, not MoltenVK. virglrenderer requires the
memory-sharing behavior provided by the Mesa/KosmicKrisp path. Guest commands
run in a separate virglrenderer render-server process because forking an active
Metal process is unsafe.

## Capability policy

Advertise only capabilities exercised through the complete guest-to-Metal
stack. The integration gate is OpenGL 4.3 by default; a lower version may be
used only as an explicit transport regression check.

The vendored KosmicKrisp patches currently provide the Zink requirements that
are missing upstream. Remove each patch when its equivalent lands upstream.
Known limitations are documented with the patch series in
`third_party/patches/mesa/`.

Guest requirements are in [gpu-venus-guest-requirements.md](gpu-venus-guest-requirements.md).
Host setup and component boundaries are in
[gpu-venus-moltenvk.md](gpu-venus-moltenvk.md).

## References

- [Mesa Zink](https://docs.mesa3d.org/drivers/zink.html)
- [Mesa Venus](https://docs.mesa3d.org/drivers/venus.html)
- [virglrenderer](https://gitlab.freedesktop.org/virgl/virglrenderer)
- [Khronos Vulkan portability guidance][vulkan-portability]

[vulkan-portability]: https://docs.vulkan.org/guide/latest/portability_initiative.html
