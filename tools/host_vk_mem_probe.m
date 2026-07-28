/*
 * host_vk_mem_probe — replicate upstream virglrenderer's vkr Metal
 * shared-memory allocation (vkr_device_memory.c + vkr_metal_helpers.m)
 * directly against KosmicKrisp, to debug guest-side blob export failures
 * without a guest boot.
 *
 * Path replicated: instance (metal-export intent) → device with
 * VK_EXT_external_memory_metal + VK_EXT_metal_objects →
 * vkExportMetalObjectsEXT → MTLDevice → shm fd + mmap +
 * newBufferWithBytesNoCopy → vkAllocateMemory with
 * VkImportMemoryMetalHandleInfoEXT (MTLBUFFER handle).
 *
 * Build:
 *   zig cc -O2 -o /tmp/host_vk_mem_probe tools/host_vk_mem_probe.m \
 *     -I/opt/homebrew/opt/vulkan-headers/include \
 *     -L/opt/homebrew/opt/vulkan-loader/lib -lvulkan \
 *     -Wl,-rpath,/opt/homebrew/opt/vulkan-loader/lib \
 *     -framework Metal -framework Foundation
 * Run:
 *   VK_ICD_FILENAMES=$HOME/.local/opt/virgl-upstream/share/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json \
 *     /tmp/host_vk_mem_probe
 */
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <vulkan/vulkan.h>
#include <vulkan/vulkan_beta.h>
#include <vulkan/vulkan_metal.h>

#define CHECK(what, r)                                                        \
   do {                                                                       \
      printf("%-50s rc=%d\n", what, (int)(r));                                \
      if ((r) != VK_SUCCESS)                                                  \
         return 1;                                                            \
   } while (0)

int main(void)
{
   /* --- instance, as vkr creates it --- */
   VkApplicationInfo app_info = {
      .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
      .apiVersion = VK_API_VERSION_1_1,
   };
   VkExportMetalObjectCreateInfoEXT export_metal_device = {
      .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECT_CREATE_INFO_EXT,
      .exportObjectType = VK_EXPORT_METAL_OBJECT_TYPE_METAL_DEVICE_BIT_EXT,
   };
   const char *inst_exts[2];
   uint32_t inst_ext_count = 0;
   inst_exts[inst_ext_count++] = "VK_KHR_portability_enumeration";
   VkInstanceCreateInfo inst_info = {
      .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
      .pNext = &export_metal_device,
      .flags = VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR,
      .pApplicationInfo = &app_info,
      .enabledExtensionCount = inst_ext_count,
      .ppEnabledExtensionNames = inst_exts,
   };
   VkInstance instance;
   CHECK("vkCreateInstance", vkCreateInstance(&inst_info, NULL, &instance));

   uint32_t dev_count = 1;
   VkPhysicalDevice phys;
   vkEnumeratePhysicalDevices(instance, &dev_count, &phys);
   if (!dev_count) {
      printf("no physical devices\n");
      return 1;
   }
   VkPhysicalDeviceProperties props;
   vkGetPhysicalDeviceProperties(phys, &props);
   printf("device: %s api=%u.%u.%u\n", props.deviceName,
          VK_API_VERSION_MAJOR(props.apiVersion),
          VK_API_VERSION_MINOR(props.apiVersion),
          VK_API_VERSION_PATCH(props.apiVersion));

   /* --- device extension survey (what vkr_physical_device records) --- */
   uint32_t ext_count = 0;
   vkEnumerateDeviceExtensionProperties(phys, NULL, &ext_count, NULL);
   VkExtensionProperties *exts = calloc(ext_count, sizeof(*exts));
   vkEnumerateDeviceExtensionProperties(phys, NULL, &ext_count, exts);
   int has_ext_mem_metal = 0, has_metal_objects = 0, has_portability = 0,
       has_timeline = 0;
   for (uint32_t i = 0; i < ext_count; i++) {
      if (!strcmp(exts[i].extensionName, "VK_EXT_external_memory_metal"))
         has_ext_mem_metal = 1;
      if (!strcmp(exts[i].extensionName, "VK_EXT_metal_objects"))
         has_metal_objects = 1;
      if (!strcmp(exts[i].extensionName, "VK_KHR_portability_subset"))
         has_portability = 1;
      if (!strcmp(exts[i].extensionName, "VK_KHR_timeline_semaphore"))
         has_timeline = 1;
   }
   printf("device exts: external_memory_metal=%d metal_objects=%d "
          "portability_subset=%d timeline_semaphore=%d (total %u)\n",
          has_ext_mem_metal, has_metal_objects, has_portability, has_timeline,
          ext_count);

   /* --- external buffer properties for MTLBUFFER import --- */
   VkPhysicalDeviceExternalBufferInfo ext_buf_info = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_BUFFER_INFO,
      .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT,
      .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLBUFFER_BIT_EXT,
   };
   VkExternalBufferProperties ext_buf_props = {
      .sType = VK_STRUCTURE_TYPE_EXTERNAL_BUFFER_PROPERTIES,
   };
   vkGetPhysicalDeviceExternalBufferProperties(phys, &ext_buf_info,
                                               &ext_buf_props);
   printf("MTLBUFFER external buffer: features=0x%x export=0x%x import=0x%x\n",
          ext_buf_props.externalMemoryProperties.externalMemoryFeatures,
          ext_buf_props.externalMemoryProperties.exportFromImportedHandleTypes,
          ext_buf_props.externalMemoryProperties.compatibleHandleTypes);

   /* --- device, as vkr creates it --- */
   const char *dev_exts[4];
   uint32_t dev_ext_count = 0;
   if (has_ext_mem_metal)
      dev_exts[dev_ext_count++] = "VK_EXT_external_memory_metal";
   if (has_metal_objects)
      dev_exts[dev_ext_count++] = "VK_EXT_metal_objects";
   if (has_portability)
      dev_exts[dev_ext_count++] = "VK_KHR_portability_subset";

   const float prio = 1.0f;
   VkDeviceQueueCreateInfo queue_info = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
      .queueFamilyIndex = 0,
      .queueCount = 1,
      .pQueuePriorities = &prio,
   };
   VkDeviceCreateInfo dev_info = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
      .queueCreateInfoCount = 1,
      .pQueueCreateInfos = &queue_info,
      .enabledExtensionCount = dev_ext_count,
      .ppEnabledExtensionNames = dev_exts,
   };
   VkDevice dev;
   CHECK("vkCreateDevice", vkCreateDevice(phys, &dev_info, NULL, &dev));

   /* --- export the MTLDevice (vkr_metal_get_device) --- */
   PFN_vkExportMetalObjectsEXT export_objects =
      (PFN_vkExportMetalObjectsEXT)vkGetDeviceProcAddr(dev,
                                                       "vkExportMetalObjectsEXT");
   printf("vkExportMetalObjectsEXT proc: %s\n", export_objects ? "ok" : "NULL");
   if (!export_objects)
      return 1;
   VkExportMetalDeviceInfoEXT metal_dev_info = {
      .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_DEVICE_INFO_EXT,
   };
   VkExportMetalObjectsInfoEXT export_objs = {
      .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT,
      .pNext = &metal_dev_info,
   };
   export_objects(dev, &export_objs);
   id<MTLDevice> mtl_device = (__bridge id<MTLDevice>)metal_dev_info.mtlDevice;
   printf("exported MTLDevice: %s\n",
          mtl_device ? [[mtl_device name] UTF8String] : "NULL");
   if (!mtl_device)
      return 1;

   /* --- shm + MTLBuffer (vkr_mtl_shm_alloc) --- */
   const size_t page = (size_t)getpagesize();
   const uint64_t want = 1048576; /* matches the failing guest blob */
   const size_t aligned = (want + page - 1) & ~(page - 1);
   char tmpl[] = "/tmp/vkr-metal-mem-XXXXXX";
   int shm_fd = mkstemp(tmpl);
   unlink(tmpl);
   if (shm_fd < 0 || ftruncate(shm_fd, (off_t)aligned) != 0) {
      printf("shm create failed\n");
      return 1;
   }
   void *shm_ptr =
      mmap(NULL, aligned, PROT_READ | PROT_WRITE, MAP_SHARED, shm_fd, 0);
   if (shm_ptr == MAP_FAILED) {
      printf("shm mmap failed\n");
      return 1;
   }
   id<MTLBuffer> mtl_buffer =
      [mtl_device newBufferWithBytesNoCopy:shm_ptr
                                    length:aligned
                                   options:MTLResourceStorageModeShared
                               deallocator:nil];
   printf("newBufferWithBytesNoCopy: %s\n", mtl_buffer ? "ok" : "NULL");
   if (!mtl_buffer)
      return 1;

   /* --- find a HOST_VISIBLE memory type --- */
   VkPhysicalDeviceMemoryProperties mem_props;
   vkGetPhysicalDeviceMemoryProperties(phys, &mem_props);
   uint32_t type_index = UINT32_MAX;
   for (uint32_t i = 0; i < mem_props.memoryTypeCount; i++) {
      if (mem_props.memoryTypes[i].propertyFlags &
          VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) {
         type_index = i;
         break;
      }
   }
   printf("HOST_VISIBLE memory type index: %u\n", type_index);

   /* --- vkAllocateMemory with MTLBUFFER import (vkr path) --- */
   VkImportMemoryMetalHandleInfoEXT metal_import = {
      .sType = VK_STRUCTURE_TYPE_IMPORT_MEMORY_METAL_HANDLE_INFO_EXT,
      .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLBUFFER_BIT_EXT,
      .handle = (__bridge void *)mtl_buffer,
   };
   VkMemoryAllocateInfo alloc_info = {
      .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
      .pNext = &metal_import,
      .allocationSize = aligned,
      .memoryTypeIndex = type_index,
   };
   VkDeviceMemory mem;
   CHECK("vkAllocateMemory(MTLBUFFER import)",
         vkAllocateMemory(dev, &alloc_info, NULL, &mem));

   /* --- map + write through, prove coherency with the shm --- */
   void *mapped = NULL;
   CHECK("vkMapMemory", vkMapMemory(dev, mem, 0, VK_WHOLE_SIZE, 0, &mapped));
   memset(mapped, 0xAB, 16);
   int coherent = ((unsigned char *)shm_ptr)[0] == 0xAB;
   printf("write-through to shm: %s\n", coherent ? "ok" : "MISMATCH");

   vkUnmapMemory(dev, mem);
   vkFreeMemory(dev, mem, NULL);
   vkDestroyDevice(dev, NULL);
   vkDestroyInstance(instance, NULL);
   printf("host_vk_mem_probe ok\n");
   return 0;
}
