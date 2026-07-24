// MoltenVK capability probe: what does this Mac's GPU expose through Vulkan?
// The features here gate what OpenGL version Zink can advertise on top.
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static int has_ext(VkExtensionProperties *e, uint32_t n, const char *name) {
    for (uint32_t i = 0; i < n; i++) if (!strcmp(e[i].extensionName, name)) return 1;
    return 0;
}

int main(void) {
    // Linking MoltenVK directly (no Vulkan loader): portability enumeration is
    // a loader concept, so no instance extensions / flags are needed here.
    VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO };
    VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
    ici.pApplicationInfo = &app;

    VkInstance inst;
    VkResult r = vkCreateInstance(&ici, NULL, &inst);
    if (r != VK_SUCCESS) { printf("vkCreateInstance failed: %d\n", r); return 1; }

    uint32_t ndev = 0;
    vkEnumeratePhysicalDevices(inst, &ndev, NULL);
    if (!ndev) { printf("no physical devices\n"); return 1; }
    VkPhysicalDevice *devs = calloc(ndev, sizeof(*devs));
    vkEnumeratePhysicalDevices(inst, &ndev, devs);
    VkPhysicalDevice pd = devs[0];

    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(pd, &props);
    printf("== device ==\n");
    printf("name: %s\n", props.deviceName);
    printf("vulkan api: %u.%u.%u\n",
        VK_VERSION_MAJOR(props.apiVersion), VK_VERSION_MINOR(props.apiVersion), VK_VERSION_PATCH(props.apiVersion));
    printf("driver: MoltenVK (driverVersion=%u)\n", props.driverVersion);

    VkPhysicalDeviceFeatures f;
    vkGetPhysicalDeviceFeatures(pd, &f);
    printf("\n== core features (GL-version gating) ==\n");
    printf("shaderFloat64:              %d   (GL 4.0 fp64 / ARB_gpu_shader_fp64)\n", f.shaderFloat64);
    printf("shaderInt64:                %d\n", f.shaderInt64);
    printf("geometryShader:             %d   (GL 3.2)\n", f.geometryShader);
    printf("tessellationShader:         %d   (GL 4.0)\n", f.tessellationShader);
    printf("multiViewport:              %d   (GL 4.1 viewport arrays)\n", f.multiViewport);
    printf("depthClamp:                 %d\n", f.depthClamp);
    printf("dualSrcBlend:               %d\n", f.dualSrcBlend);
    printf("logicOp:                    %d\n", f.logicOp);
    printf("multiDrawIndirect:          %d   (GL 4.3 indirect)\n", f.multiDrawIndirect);
    printf("drawIndirectFirstInstance:  %d\n", f.drawIndirectFirstInstance);
    printf("fillModeNonSolid:           %d   (glPolygonMode)\n", f.fillModeNonSolid);
    printf("imageCubeArray:             %d   (GL 4.0)\n", f.imageCubeArray);
    printf("shaderStorageImageMultisample: %d\n", f.shaderStorageImageMultisample);
    printf("shaderClipDistance:         %d\n", f.shaderClipDistance);
    printf("shaderCullDistance:         %d\n", f.shaderCullDistance);
    printf("occlusionQueryPrecise:      %d\n", f.occlusionQueryPrecise);
    printf("pipelineStatisticsQuery:    %d\n", f.pipelineStatisticsQuery);
    printf("samplerAnisotropy:          %d\n", f.samplerAnisotropy);
    printf("textureCompressionBC:       %d\n", f.textureCompressionBC);
    printf("textureCompressionETC2:     %d\n", f.textureCompressionETC2);
    printf("wideLines:                  %d\n", f.wideLines);
    printf("largePoints:                %d\n", f.largePoints);
    printf("independentBlend:           %d\n", f.independentBlend);

    // limits relevant to GL 4.3
    printf("\n== limits ==\n");
    printf("maxComputeSharedMemorySize: %u\n", props.limits.maxComputeSharedMemorySize);
    printf("maxComputeWorkGroupInvocations: %u\n", props.limits.maxComputeWorkGroupInvocations);
    printf("maxUniformBufferRange:      %u\n", props.limits.maxUniformBufferRange);
    printf("maxStorageBufferRange:      %u\n", props.limits.maxStorageBufferRange);
    printf("maxPerStageDescriptorStorageBuffers: %u   (SSBOs, GL 4.3)\n", props.limits.maxPerStageDescriptorStorageBuffers);
    printf("maxColorAttachments:        %u\n", props.limits.maxColorAttachments);
    printf("maxImageDimension2D:        %u\n", props.limits.maxImageDimension2D);
    printf("maxVertexInputAttributes:   %u\n", props.limits.maxVertexInputAttributes);
    printf("maxFragmentOutputAttachments: %u\n", props.limits.maxFragmentOutputAttachments);

    // device extensions Zink cares about
    uint32_t next = 0;
    vkEnumerateDeviceExtensionProperties(pd, NULL, &next, NULL);
    VkExtensionProperties *exts = calloc(next, sizeof(*exts));
    vkEnumerateDeviceExtensionProperties(pd, NULL, &next, exts);
    printf("\n== key device extensions (%u total) ==\n", next);
    const char *want[] = {
        "VK_EXT_transform_feedback",       // GL transform feedback (the Metal wall for hand-rolling)
        "VK_EXT_vertex_attribute_divisor", // instanced arrays
        "VK_EXT_provoking_vertex",         // GL provoking vertex convention
        "VK_EXT_line_rasterization",
        "VK_EXT_custom_border_color",
        "VK_KHR_maintenance1",
        "VK_KHR_maintenance2",
        "VK_KHR_create_renderpass2",
        "VK_EXT_descriptor_indexing",      // bindless-ish, GL 4.x
        "VK_EXT_robustness2",
        "VK_KHR_swapchain",
        "VK_EXT_shader_viewport_index_layer",
        "VK_EXT_conditional_rendering",    // GL conditional render
        "VK_EXT_depth_clip_enable",
        "VK_EXT_4444_formats",
        "VK_KHR_shader_draw_parameters",
        "VK_EXT_image_2d_view_of_3d",
        "VK_EXT_multi_draw",
        "VK_KHR_dynamic_rendering",
    };
    for (unsigned i = 0; i < sizeof(want)/sizeof(*want); i++)
        printf("  %-40s %s\n", want[i], has_ext(exts, next, want[i]) ? "YES" : "-- MISSING --");

    // transform-feedback feature detail (the decisive one)
    if (has_ext(exts, next, "VK_EXT_transform_feedback")) {
        VkPhysicalDeviceTransformFeedbackFeaturesEXT tf = {
            .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TRANSFORM_FEEDBACK_FEATURES_EXT };
        VkPhysicalDeviceFeatures2 f2 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &tf };
        vkGetPhysicalDeviceFeatures2(pd, &f2);
        printf("\n== VK_EXT_transform_feedback detail ==\n");
        printf("transformFeedback: %d   geometryStreams: %d\n", tf.transformFeedback, tf.geometryStreams);
    }

    printf("\nprobe ok\n");
    return 0;
}
