// Does KosmicKrisp report the external-memory export venus requires of a
// physical device (vkr_physical_device.c)? venus needs at least one of dma_buf,
// opaque_fd, or MTLHEAP export to be EXPORTABLE, else it rejects the device.
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#ifndef VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLHEAP_BIT_EXT
#define VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLHEAP_BIT_EXT 0x00001000
#endif

static int has_ext(VkExtensionProperties *e, uint32_t n, const char *s){for(uint32_t i=0;i<n;i++)if(!strcmp(e[i].extensionName,s))return 1;return 0;}

static void check(VkPhysicalDevice pd, const char *name, VkExternalMemoryHandleTypeFlagBits ht) {
    VkPhysicalDeviceExternalBufferInfo info = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_BUFFER_INFO,
        .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT, .handleType = ht };
    VkExternalBufferProperties props = { .sType = VK_STRUCTURE_TYPE_EXTERNAL_BUFFER_PROPERTIES };
    vkGetPhysicalDeviceExternalBufferProperties(pd, &info, &props);
    VkExternalMemoryFeatureFlags f = props.externalMemoryProperties.externalMemoryFeatures;
    VkExternalMemoryHandleTypeFlags ex = props.externalMemoryProperties.exportFromImportedHandleTypes;
    int exportable = (f & VK_EXTERNAL_MEMORY_FEATURE_EXPORTABLE_BIT) && (ex & ht);
    printf("  %-12s features=0x%x export_types=0x%x  -> venus_exportable=%s\n",
           name, f, ex, exportable ? "YES" : "no");
}

int main(void){
    VkInstanceCreateInfo ici={.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    VkApplicationInfo app={.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO,.apiVersion=VK_API_VERSION_1_3};
    ici.pApplicationInfo=&app;
    VkInstance inst; if(vkCreateInstance(&ici,NULL,&inst)){printf("createInstance failed\n");return 1;}
    uint32_t n=0; vkEnumeratePhysicalDevices(inst,&n,NULL);
    if(!n){printf("no physical devices\n");return 1;}
    VkPhysicalDevice *d=calloc(n,sizeof(*d)); vkEnumeratePhysicalDevices(inst,&n,d);
    VkPhysicalDevice pd=d[0];
    VkPhysicalDeviceProperties p; vkGetPhysicalDeviceProperties(pd,&p);
    printf("device: %s (api %u.%u)\n",p.deviceName,VK_VERSION_MAJOR(p.apiVersion),VK_VERSION_MINOR(p.apiVersion));

    uint32_t ec=0; vkEnumerateDeviceExtensionProperties(pd,NULL,&ec,NULL);
    VkExtensionProperties *e=calloc(ec,sizeof(*e)); vkEnumerateDeviceExtensionProperties(pd,NULL,&ec,e);
    printf("VK_EXT_external_memory_metal: %s\n", has_ext(e,ec,"VK_EXT_external_memory_metal")?"present":"MISSING");
    printf("VK_KHR_external_memory_fd:    %s\n", has_ext(e,ec,"VK_KHR_external_memory_fd")?"present":"MISSING");
    printf("VK_EXT_external_memory_dma_buf: %s\n", has_ext(e,ec,"VK_EXT_external_memory_dma_buf")?"present":"MISSING");
    printf("\nvenus per-device external-memory EXPORT checks (needs >=1 YES):\n");
    check(pd,"MTLHEAP", VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLHEAP_BIT_EXT);
    check(pd,"OPAQUE_FD", VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT);
    return 0;
}
