# Vendored GPU stack

The guest GL/Vulkan path is `Zink → Venus → bobrvm → virglrenderer →
KosmicKrisp → Metal`. `pins.env` and `patches/` define the vendored
virglrenderer and Mesa/KosmicKrisp revisions; generated checkouts under `src/`
are ignored.

The virglrenderer patches provide host-pointer shared-memory import for
KosmicKrisp. The Mesa patches carry Vulkan features required by Zink until
equivalent support is available upstream.

```sh
third_party/sync.sh
third_party/build.sh
zig build -Dgpu-venus
```

To update a fork, edit and commit in `src/<name>`, regenerate its patch series
with `git format-patch <pin>.. -o ../../patches/<name>/`, and commit the new
patches. To update a revision, change `pins.env`, rerun `sync.sh`, and resolve
or regenerate the series.
