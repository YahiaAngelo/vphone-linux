// Does the driver read back, through an input attachment of the same subpass (no
// rasterization-order access), what earlier draws wrote, given a BY_REGION self-dependency
// barrier between draws? Clear 0.75; fetch*0.5; white; fetch*0.5; fetch*0.5 -> expect 0.25.
// argv[1] = "nobarrier" drops the barriers (expected undefined).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_) { fprintf(stderr, "%s = %d\n", #x, r_); exit(1); } } while (0)
enum { W = 64, H = 64 };

static VkShaderModule load(VkDevice d, const char* path) {
    FILE* f = fopen(path, "rb"); fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f);
    void* b = malloc(n); fread(b, 1, n, f); fclose(f);
    VkShaderModuleCreateInfo ci = {VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, 0, 0, n, b};
    VkShaderModule m; CK(vkCreateShaderModule(d, &ci, 0, &m)); return m;
}

static uint32_t memtype(VkPhysicalDevice pd, uint32_t bits, VkMemoryPropertyFlags want) {
    VkPhysicalDeviceMemoryProperties mp; vkGetPhysicalDeviceMemoryProperties(pd, &mp);
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
        if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want) return i;
    exit(2);
}

int main(int argc, char** argv) {
    int barriers = !(argc > 1 && !strcmp(argv[1], "nobarrier"));
    VkFormat fmt = VK_FORMAT_R16G16B16A16_SFLOAT;
    VkApplicationInfo ai = {VK_STRUCTURE_TYPE_APPLICATION_INFO, 0, "fetchtest", 1, 0, 0, VK_API_VERSION_1_2};
    VkInstanceCreateInfo ici = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, 0, 0, &ai};
    VkInstance inst; CK(vkCreateInstance(&ici, 0, &inst));
    uint32_t n = 8; VkPhysicalDevice pds[8]; CK(vkEnumeratePhysicalDevices(inst, &n, pds));
    VkPhysicalDevice pd = pds[0];
    VkPhysicalDeviceProperties pp; vkGetPhysicalDeviceProperties(pd, &pp); printf("device: %s\n", pp.deviceName);
    float prio = 1;
    VkDeviceQueueCreateInfo qci = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, 0, 0, 0, 1, &prio};
    VkDeviceCreateInfo dci = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, 0, 0, 1, &qci};
    VkDevice d; CK(vkCreateDevice(pd, &dci, 0, &d));
    VkQueue q; vkGetDeviceQueue(d, 0, 0, &q);

    VkImageCreateInfo ii = {VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, 0, 0, VK_IMAGE_TYPE_2D, fmt, {W, H, 1}, 1, 1,
        VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_TILING_OPTIMAL,
        VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_INPUT_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
        VK_SHARING_MODE_EXCLUSIVE, 0, 0, VK_IMAGE_LAYOUT_UNDEFINED};
    VkImage img; CK(vkCreateImage(d, &ii, 0, &img));
    VkMemoryRequirements mr; vkGetImageMemoryRequirements(d, img, &mr);
    VkMemoryAllocateInfo ma = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, 0, mr.size,
        memtype(pd, mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)};
    VkDeviceMemory im; CK(vkAllocateMemory(d, &ma, 0, &im)); CK(vkBindImageMemory(d, img, im, 0));
    VkImageViewCreateInfo vi = {VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, 0, 0, img, VK_IMAGE_VIEW_TYPE_2D, fmt, {0},
        {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
    VkImageView view; CK(vkCreateImageView(d, &vi, 0, &view));

    VkBufferCreateInfo bi = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, 0, 0, W * H * 8, VK_BUFFER_USAGE_TRANSFER_DST_BIT};
    VkBuffer buf; CK(vkCreateBuffer(d, &bi, 0, &buf));
    vkGetBufferMemoryRequirements(d, buf, &mr);
    ma.allocationSize = mr.size;
    ma.memoryTypeIndex = memtype(pd, mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    VkDeviceMemory bm; CK(vkAllocateMemory(d, &ma, 0, &bm)); CK(vkBindBufferMemory(d, buf, bm, 0));

    VkAttachmentDescription att = {0, fmt, VK_SAMPLE_COUNT_1_BIT, VK_ATTACHMENT_LOAD_OP_CLEAR, VK_ATTACHMENT_STORE_OP_STORE,
        VK_ATTACHMENT_LOAD_OP_DONT_CARE, VK_ATTACHMENT_STORE_OP_DONT_CARE, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_GENERAL};
    VkAttachmentReference ref = {0, VK_IMAGE_LAYOUT_GENERAL};
    VkSubpassDescription sp = {0, VK_PIPELINE_BIND_POINT_GRAPHICS, 1, &ref, 1, &ref};
    VkPipelineStageFlags st = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
    VkSubpassDependency dep = {0, 0, st, st, VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        VK_ACCESS_INPUT_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, VK_DEPENDENCY_BY_REGION_BIT};
    VkRenderPassCreateInfo rpi = {VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, 0, 0, 1, &att, 1, &sp, 1, &dep};
    VkRenderPass rp; CK(vkCreateRenderPass(d, &rpi, 0, &rp));
    VkFramebufferCreateInfo fi = {VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO, 0, 0, rp, 1, &view, W, H, 1};
    VkFramebuffer fb; CK(vkCreateFramebuffer(d, &fi, 0, &fb));

    VkDescriptorSetLayoutBinding lb = {0, VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT, 1, VK_SHADER_STAGE_FRAGMENT_BIT};
    VkDescriptorSetLayoutCreateInfo dli = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, 0, 0, 1, &lb};
    VkDescriptorSetLayout dsl; CK(vkCreateDescriptorSetLayout(d, &dli, 0, &dsl));
    VkPipelineLayoutCreateInfo pli = {VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, 0, 0, 1, &dsl};
    VkPipelineLayout pl; CK(vkCreatePipelineLayout(d, &pli, 0, &pl));
    VkDescriptorPoolSize ps = {VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT, 1};
    VkDescriptorPoolCreateInfo dpi = {VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, 0, 0, 1, 1, &ps};
    VkDescriptorPool dp; CK(vkCreateDescriptorPool(d, &dpi, 0, &dp));
    VkDescriptorSetAllocateInfo dai = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, 0, dp, 1, &dsl};
    VkDescriptorSet ds; CK(vkAllocateDescriptorSets(d, &dai, &ds));
    VkDescriptorImageInfo dii = {0, view, VK_IMAGE_LAYOUT_GENERAL};
    VkWriteDescriptorSet w = {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, 0, ds, 0, 0, 1, VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT, &dii};
    vkUpdateDescriptorSets(d, 1, &w, 0, 0);

    VkShaderModule vs = load(d, "tri.vert.spv");
    VkPipeline pipes[2];
    const char* frags[2] = {"fetch.frag.spv", "white.frag.spv"};
    for (int i = 0; i < 2; i++) {
        VkPipelineShaderStageCreateInfo stg[2] = {
            {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, 0, 0, VK_SHADER_STAGE_VERTEX_BIT, vs, "main"},
            {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, 0, 0, VK_SHADER_STAGE_FRAGMENT_BIT, load(d, frags[i]), "main"}};
        VkPipelineVertexInputStateCreateInfo vin = {VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
        VkPipelineInputAssemblyStateCreateInfo ia = {VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, 0, 0, VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST};
        VkViewport vp = {0, 0, W, H, 0, 1}; VkRect2D sc = {{0, 0}, {W, H}};
        VkPipelineViewportStateCreateInfo vps = {VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, 0, 0, 1, &vp, 1, &sc};
        VkPipelineRasterizationStateCreateInfo rs = {VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO};
        rs.lineWidth = 1;
        VkPipelineMultisampleStateCreateInfo ms = {VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, 0, 0, VK_SAMPLE_COUNT_1_BIT};
        VkPipelineColorBlendAttachmentState cba = {0}; cba.colorWriteMask = 0xf;
        VkPipelineColorBlendStateCreateInfo cb = {VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, 0, 0, 0, 0, 1, &cba};
        VkGraphicsPipelineCreateInfo gp = {VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, 0, 0, 2, stg, &vin, &ia, 0, &vps, &rs, &ms, 0, &cb, 0, pl, rp, 0};
        CK(vkCreateGraphicsPipelines(d, 0, 1, &gp, 0, &pipes[i]));
    }

    VkCommandPoolCreateInfo cpi = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, 0, 0, 0};
    VkCommandPool cp; CK(vkCreateCommandPool(d, &cpi, 0, &cp));
    VkCommandBufferAllocateInfo cai = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, 0, cp, VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1};
    VkCommandBuffer c; CK(vkAllocateCommandBuffers(d, &cai, &c));
    VkCommandBufferBeginInfo cbi = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    CK(vkBeginCommandBuffer(c, &cbi));
    VkClearValue clear = {.color = {{0.75f, 0.75f, 0.75f, 0.75f}}};
    VkRenderPassBeginInfo rbi = {VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, 0, rp, fb, {{0, 0}, {W, H}}, 1, &clear};
    vkCmdBeginRenderPass(c, &rbi, VK_SUBPASS_CONTENTS_INLINE);
    vkCmdBindDescriptorSets(c, VK_PIPELINE_BIND_POINT_GRAPHICS, pl, 0, 1, &ds, 0, 0);
    int seq[4] = {0, 1, 0, 0};
    int overlap = argc > 1 && !strcmp(argv[1], "overlap");
    int oseq[2] = {1, 0}; int first = argc > 2;
    for (int i = first; i < (overlap ? 2 : 4); i++) {
        if ((i || first) && barriers) {
            VkMemoryBarrier mb = {VK_STRUCTURE_TYPE_MEMORY_BARRIER, 0, VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
                VK_ACCESS_INPUT_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT};
            vkCmdPipelineBarrier(c, st, st, VK_DEPENDENCY_BY_REGION_BIT, 1, &mb, 0, 0, 0, 0);
        }
        vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, pipes[overlap ? oseq[i] : seq[i]]);
        vkCmdDraw(c, 3, overlap && i == 1 ? 2 : 1, 0, 0);
    }
    vkCmdEndRenderPass(c);
    VkBufferImageCopy bic = {0, 0, 0, {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {0, 0, 0}, {W, H, 1}};
    VkMemoryBarrier mb = {VK_STRUCTURE_TYPE_MEMORY_BARRIER, 0, VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT};
    vkCmdPipelineBarrier(c, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 1, &mb, 0, 0, 0, 0);
    vkCmdCopyImageToBuffer(c, img, VK_IMAGE_LAYOUT_GENERAL, buf, 1, &bic);
    CK(vkEndCommandBuffer(c));
    VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO, 0, 0, 0, 0, 1, &c};
    CK(vkQueueSubmit(q, 1, &si, 0)); CK(vkQueueWaitIdle(q));
    _Float16* px; CK(vkMapMemory(d, bm, 0, W * H * 8, 0, (void**)&px));
    int bad = 0;
    for (int i = 0; i < W * H; i++) if ((float)px[i * 4] != (overlap ? 0.25f : 0.25f)) bad++;
    printf("barriers=%d pixel0=%g center=%g; %d of %d pixels != 0.25 (expect 0.25; no fetch of white = 0.09375; fetch of clear only = 0.375 or 0.1875)\n",
           barriers, (float)px[0], (float)px[(H / 2 * W + W / 2) * 4], bad, W * H);
    return bad != 0;
}
