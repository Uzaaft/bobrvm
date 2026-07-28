# Vendored GPU stack

bobrvm's guest GL/Vulkan path is `guest zink → venus → bobrvm virtio-gpu →
virglrenderer → KosmicKrisp → Metal`. Two components are vendored as
**pin + patch series** (the checkouts under `src/` are gitignored; the fork
is fully defined by `pins.env` + `patches/`):

| Component | Why forked |
|---|---|
| `virglrenderer` | host-pointer shm import (`VK_EXT_external_memory_host`) so venus works on KosmicKrisp, which lacks `VK_EXT_metal_objects`. Upstream-worthy; submit to virgl/virglrenderer. |
| `mesa` (KosmicKrisp) | the zink GL-version gates LunarG hasn't shipped yet: `VK_EXT_transform_feedback`, `geometryShader`, `VK_EXT_depth_clip_enable`. Mesa main already stages TF properties and ships the `poly` compute-geometry library (Asahi-derived) that KK uses for tessellation — our patches wire the rest. Drop patches as upstream lands equivalents. |

## Workflow

```sh
third_party/sync.sh    # checkout pinned SHAs into src/, apply patches/
third_party/build.sh   # build + install both (virgl → ~/.local/opt/virgl-upstream, KK dylib → /opt/homebrew/lib)
zig build -Dgpu-venus  # bobrvm against the stack
```

To change the fork: edit in `src/<name>`, commit there, regenerate the series
(`git format-patch <pin>.. -o ../../patches/<name>/`), and commit the patch
files here. To uprev: bump `pins.env`, re-run `sync.sh`, fix conflicts,
regenerate.

## Upstream MRs of interest

See the "Upstream MRs of interest" section in the top-level README.md —
virglrenderer macOS support (!1600/!1601/!1602/!1635) and the KosmicKrisp
geometry-pipeline work (mesa!41568, mesa!42020, mesa!43091). When LunarG
lands `VK_EXT_transform_feedback` + `geometryShader` in KK, drop our mesa
patches and uprev instead.
