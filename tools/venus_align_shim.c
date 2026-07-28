/*
 * venus_align_shim.so — guest-side LD_PRELOAD shim for Venus on Apple Silicon
 * hosts (16KiB host pages).
 *
 * Problem: the guest venus driver (Mesa vn_renderer_virtgpu.c) creates
 * HOST3D host-visible blobs with 4KiB-aligned sizes, so the guest kernel's
 * drm_mm packs consecutive blobs at 4KiB-aligned offsets inside the
 * host-visible BAR window. The macOS host maps blobs into that window with
 * hv_vm_map(), which needs 16KiB (Apple page) alignment — a blob landing at
 * a non-16KiB offset cannot be mapped and venus dies with
 * VK_ERROR_OUT_OF_HOST_MEMORY.
 *
 * Fix (same as osy/UTM's guest Mesa patch,
 * gist.github.com/osy/a8f705050eed1c8421ad1a0855a8faa9): round HOST3D blob
 * *sizes* up to 16KiB at DRM_IOCTL_VIRTGPU_RESOURCE_CREATE_BLOB time — then
 * drm_mm naturally places every blob at a 16KiB-aligned offset, even on a
 * 4KiB-page guest kernel. The mmap *length* must be rounded identically:
 * virtio_gpu_vram_mmap() rejects vm_size != vram_node.size.
 *
 * Interposes only ioctl() and mmap(), forwarding via raw syscall() — NOT
 * dlsym(RTLD_NEXT): an mmap interposer that calls dlsym deadlocks, because
 * dlsym itself mmaps.
 *
 * Cross-compile from the macOS host:
 *   zig cc -target aarch64-linux-gnu.2.34 -shared -fPIC -O2 \
 *     -o venus_align_shim.so tools/venus_align_shim.c
 */
#define _GNU_SOURCE
#include <stdarg.h>
#include <stdint.h>
#include <sys/syscall.h>
#include <unistd.h>

#define APPLE_PAGE 0x4000UL

/* linux asm-generic ioctl encoding */
#define SHIM_IOC(dir, type, nr, size) \
   (((unsigned)(dir) << 30) | ((unsigned)(size) << 16) | \
    ((unsigned)(type) << 8) | (unsigned)(nr))
#define SHIM_IOC_READWRITE 3U

struct drm_virtgpu_resource_create_blob {
   uint32_t blob_mem;
   uint32_t blob_flags;
   uint32_t bo_handle;
   uint32_t res_handle;
   uint64_t size;
   uint32_t pad;
   uint32_t cmd_size;
   uint64_t cmd;
   uint64_t blob_id;
};

#define VIRTGPU_BLOB_MEM_HOST3D 0x0002u
/* DRM_IOWR(DRM_COMMAND_BASE + DRM_VIRTGPU_RESOURCE_CREATE_BLOB, ...) */
#define DRM_IOCTL_VIRTGPU_RESOURCE_CREATE_BLOB               \
   SHIM_IOC(SHIM_IOC_READWRITE, 'd', 0x40 + 0x0a,            \
            sizeof(struct drm_virtgpu_resource_create_blob))

/* fds seen doing virtgpu blob creation; mmap lengths on these get rounded. */
#define MAX_FDS 16
static int learned_fds[MAX_FDS];
static int learned_count;

static void learn_fd(int fd)
{
   for (int i = 0; i < learned_count; i++)
      if (learned_fds[i] == fd)
         return;
   if (learned_count < MAX_FDS)
      learned_fds[learned_count++] = fd;
}

static int is_learned(int fd)
{
   for (int i = 0; i < learned_count; i++)
      if (learned_fds[i] == fd)
         return 1;
   return 0;
}

int ioctl(int fd, unsigned long request, ...)
{
   va_list ap;
   va_start(ap, request);
   void *arg = va_arg(ap, void *);
   va_end(ap);

   if (request == DRM_IOCTL_VIRTGPU_RESOURCE_CREATE_BLOB && arg) {
      struct drm_virtgpu_resource_create_blob *blob = arg;
      learn_fd(fd);
      if (blob->blob_mem == VIRTGPU_BLOB_MEM_HOST3D)
         blob->size = (blob->size + APPLE_PAGE - 1) & ~(APPLE_PAGE - 1);
   }
   return (int)syscall(SYS_ioctl, fd, request, arg);
}

void *mmap(void *addr, size_t length, int prot, int flags, int fd,
           off_t offset)
{
   if (fd >= 0 && is_learned(fd))
      length = (length + APPLE_PAGE - 1) & ~(APPLE_PAGE - 1);
   return (void *)syscall(SYS_mmap, addr, length, prot, flags, fd, offset);
}

/* glibc exports mmap64 as a distinct symbol on some configs; alias it. */
void *mmap64(void *addr, size_t length, int prot, int flags, int fd,
             off_t offset) __attribute__((alias("mmap")));
