/*
 * host_vk_probe — replicate vkr's exact host-side vkCreateInstance to debug
 * guest-visible VK_ERROR_INCOMPATIBLE_DRIVER without a 5-minute guest boot.
 *
 * Mirrors vkr_dispatch_vkCreateInstance (upstream virglrenderer
 * src/venus/vkr_instance.c): EnumerateInstanceVersion, portability
 * enumeration when the loader offers it, VkExportMetalObjectCreateInfoEXT
 * (METAL_DEVICE export intent), apiVersion 1.1.
 *
 * Build:
 *   zig cc -O2 -o /tmp/host_vk_probe tools/host_vk_probe.c \
 *     -I/opt/homebrew/opt/vulkan-headers/include \
 *     -L/opt/homebrew/opt/vulkan-loader/lib -lvulkan \
 *     -Wl,-rpath,/opt/homebrew/opt/vulkan-loader/lib
 * Run:
 *   VK_ICD_FILENAMES=$HOME/.local/opt/virgl-upstream/share/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json \
 *     /tmp/host_vk_probe
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

int main(void)
{
   uint32_t version = 0;
   VkResult r = vkEnumerateInstanceVersion(&version);
   printf("EnumerateInstanceVersion: rc=%d version=%u.%u.%u\n", r,
          VK_API_VERSION_MAJOR(version), VK_API_VERSION_MINOR(version),
          VK_API_VERSION_PATCH(version));

   uint32_t ext_count = 0;
   vkEnumerateInstanceExtensionProperties(NULL, &ext_count, NULL);
   VkExtensionProperties *exts = calloc(ext_count, sizeof(*exts));
   vkEnumerateInstanceExtensionProperties(NULL, &ext_count, exts);
   int has_portability = 0;
   for (uint32_t i = 0; i < ext_count; i++) {
      if (!strcmp(exts[i].extensionName, "VK_KHR_portability_enumeration"))
         has_portability = 1;
   }
   printf("instance extensions: %u, portability_enumeration=%d\n", ext_count,
          has_portability);

   const char *ext_names[8];
   uint32_t ext_name_count = 0;

   VkApplicationInfo app_info = {
      .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
      .apiVersion = VK_API_VERSION_1_1,
   };
   VkInstanceCreateInfo create_info = {
      .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
      .pApplicationInfo = &app_info,
   };
   if (has_portability) {
      create_info.flags |= 0x00000001; /* ENUMERATE_PORTABILITY_BIT_KHR */
      ext_names[ext_name_count++] = "VK_KHR_portability_enumeration";
   }

   /* vkr's Metal device export intent (VK_EXT_metal_objects) */
   typedef struct {
      VkStructureType sType;
      const void *pNext;
      int exportObjectType;
   } ExportMetalObjectCreateInfoEXT;
   ExportMetalObjectCreateInfoEXT export_metal = {
      .sType = (VkStructureType)1000311000, /* EXPORT_METAL_OBJECT_CREATE_INFO_EXT */
      .pNext = NULL,
      .exportObjectType = 0x00000004, /* METAL_DEVICE_BIT_EXT */
   };
   create_info.pNext = &export_metal;
   create_info.enabledExtensionCount = ext_name_count;
   create_info.ppEnabledExtensionNames = ext_names;

   VkInstance instance = VK_NULL_HANDLE;
   r = vkCreateInstance(&create_info, NULL, &instance);
   printf("CreateInstance(with metal-export pNext): rc=%d\n", r);

   if (r != VK_SUCCESS) {
      /* retry without the metal export struct */
      create_info.pNext = NULL;
      r = vkCreateInstance(&create_info, NULL, &instance);
      printf("CreateInstance(no pNext): rc=%d\n", r);
   }
   if (r != VK_SUCCESS)
      return 1;

   uint32_t dev_count = 0;
   r = vkEnumeratePhysicalDevices(instance, &dev_count, NULL);
   printf("EnumeratePhysicalDevices: rc=%d count=%u\n", r, dev_count);
   if (dev_count) {
      VkPhysicalDevice devs[8];
      uint32_t n = dev_count < 8 ? dev_count : 8;
      vkEnumeratePhysicalDevices(instance, &n, devs);
      for (uint32_t i = 0; i < n; i++) {
         VkPhysicalDeviceProperties props;
         vkGetPhysicalDeviceProperties(devs[i], &props);
         printf("  device[%u]: %s api=%u.%u.%u\n", i, props.deviceName,
                VK_API_VERSION_MAJOR(props.apiVersion),
                VK_API_VERSION_MINOR(props.apiVersion),
                VK_API_VERSION_PATCH(props.apiVersion));
      }
   }
   vkDestroyInstance(instance, NULL);
   printf("host_vk_probe ok\n");
   return 0;
}
