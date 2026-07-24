// virglrenderer(venus) smoke test: does the host stack initialize on this Mac,
// and does it report the Venus capset? This is milestone 2's proof point.
#include <virgl/virglrenderer.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// Venus capset id (mesa/virglrenderer: VIRGL=1, VIRGL2=2, GFXSTREAM=3, VENUS=4).
#define CAPSET_VIRGL  1
#define CAPSET_VIRGL2 2
#define CAPSET_VENUS  4

static void on_write_fence(void *cookie, uint32_t fence) { (void)cookie; (void)fence; }

static void dump_capset(const char *name, uint32_t id) {
    uint32_t ver = 0, size = 0;
    virgl_renderer_get_cap_set(id, &ver, &size);
    printf("  capset %-7s (id %u): max_ver=%u  max_size=%u  -> %s\n",
        name, id, ver, size, size ? "PRESENT" : "absent");
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    fprintf(stderr, "[enter main]\n");
    struct virgl_renderer_callbacks cb;
    memset(&cb, 0, sizeof(cb));
    cb.version = 1;                 // v1: only write_fence is read
    cb.write_fence = on_write_fence;

    // Flag combos to try, most-specific first. Venus needs an EGL display
    // (ANGLE) for context/fence integration in this macOS build.
    int flags = (argc > 1) ? (int)strtol(argv[1], NULL, 0)
                           : (VIRGL_RENDERER_VENUS | VIRGL_RENDERER_USE_EGL |
                              VIRGL_RENDERER_USE_SURFACELESS | VIRGL_RENDERER_THREAD_SYNC);
    printf("virgl_renderer_init(flags=0x%x)...\n", flags);
    fflush(stdout);

    int r = virgl_renderer_init(NULL, flags, &cb);
    printf("virgl_renderer_init -> %d (%s)\n", r, r == 0 ? "OK" : "FAIL");
    if (r != 0) return 1;

    printf("capsets:\n");
    dump_capset("VIRGL",  CAPSET_VIRGL);
    dump_capset("VIRGL2", CAPSET_VIRGL2);
    dump_capset("VENUS",  CAPSET_VENUS);

    virgl_renderer_cleanup(NULL);
    printf("smoke ok\n");
    return 0;
}
