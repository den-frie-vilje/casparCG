# Ultralight Vulkan Migration Plan

<!-- Copyright (c) Den Frie Vilje (hej@denfrievilje.dk) -->

## Context

CasparCG PR [#1677](https://github.com/CasparCG/server/pull/1677) adds a
Vulkan accelerator as a drop-in replacement for the OpenGL mixer. It targets
**Vulkan 1.3** (device requirement) with VMA using 1.4.

Ultralight's `GPUDriver` interface supports custom rendering backends
including Vulkan. This document plans the migration of the Ultralight
producer from CPU bitmap rendering to Vulkan-accelerated rendering, sharing
the same Vulkan device and API version as the CasparCG mixer.

## Target API version

**Vulkan 1.3** — matching PR #1677's `require_api_version(VK_API_VERSION_1_3)`.

Key 1.3 features that simplify the GPUDriver:
- Dynamic rendering (`VK_KHR_dynamic_rendering`) — no render pass objects
- Synchronisation2 (`VK_KHR_synchronization2`) — simpler pipeline barriers
- Maintenance4 (`VK_KHR_maintenance4`) — relaxed requirements

## Current architecture (CPU bitmap)

```
Ultralight CPU render -> bitmap (BGRA) -> memcpy -> PBO -> GPU texture -> composite -> readback
```

Every frame does a full CPU rasterisation plus one `memcpy` into CasparCG's
PBO-backed frame buffer.

## PR #1677 Vulkan mixer architecture

```
vulkan::device                      (VkDevice + VMA allocator + command pools)
  |- vulkan::texture                (VkImage + VkImageView + VMA allocation)
  |- vulkan::buffer                 (VkBuffer — staging + vertex/index)
  |- vulkan::pipeline               (VkPipeline — fragment/vertex shaders)
  |- vulkan::renderpass             (VkRenderPass + VkFramebuffer)
  +- vulkan::image_mixer            (visitor pattern, composites frames)
       +- copy_async(array<uint8_t>) -> shared_ptr<texture>
```

Key API from `vulkan::device`:
- `create_texture(w, h, stride, depth, clear)` — allocates VkImage
- `copy_async(source, w, h, stride, depth)` — uploads CPU data to texture
- `dispatch_async/dispatch_sync` — same pattern as OGL device

## Collision analysis with PR #1714

PR [#1714](https://github.com/CasparCG/server/pull/1714) (OAL + screen
consumer fixes) has **zero conflicts** with our changes. Only shared file
is `casparcg.config` in non-overlapping regions. Can be merged in any order.

## Migration plan

### Phase 1: Vulkan GPUDriver with shared VkDevice

Ultralight renders directly to a VkImage that CasparCG's mixer composites.

```
Ultralight Vulkan GPUDriver -> VkImage -> CasparCG vulkan::texture -> compositor
```

1. **Implement `ultralight_vulkan_gpu_driver`** (~400 lines)

   | GPUDriver method | Vulkan implementation |
   |---|---|
   | `CreateTexture` | `vkCreateImage` + `vmaAllocateMemory` |
   | `CreateRenderBuffer` | Dynamic rendering (Vulkan 1.3) |
   | `CreateGeometry` | `vkCreateBuffer` for VBO/IBO |
   | `UpdateCommandList` | Record into `VkCommandBuffer` |
   | `BeginSynchronize` | Acquire command buffer |
   | `EndSynchronize` | Submit to queue |

2. **Share VkDevice via frame_factory**

   Pass `shared_ptr<vulkan::device>` to the Ultralight producer. Add a
   `vulkan_device()` accessor to the frame factory / accelerator interface.

3. **Expose render target as `vulkan::texture`**

   After `Renderer::Render()`, wrap the VkImage in `vulkan::texture` and
   return directly to the mixer. Requires `mutable_frame` to optionally
   hold a `shared_ptr<vulkan::texture>` (GPU data) instead of only
   `array<uint8_t>` (CPU data).

4. **Cross-compile Ultralight GLSL to SPIR-V**

   Use `glslangValidator` at build time, embed via `bin2c` (same pattern
   as PR #1677).

### Phase 2: CPU fallback

```cpp
if (auto vk = std::dynamic_pointer_cast<vulkan::device>(accelerator_device)) {
    gpu_driver_ = std::make_unique<ultralight_vulkan_gpu_driver>(vk);
    config.is_accelerated = true;
} else {
    config.is_accelerated = false;  // current CPU bitmap path
}
```

### Phase 3: macOS via MoltenVK

Vulkan 1.3 on macOS via MoltenVK. When CasparCG's Vulkan mixer works on
macOS (PR #1677 has initial support), Ultralight's GPUDriver works
automatically. Also enables Podman + libkrun GPU passthrough path.

## File plan

| File | Action | Lines (est.) |
|---|---|---|
| `ultralight/vulkan/ultralight_gpu_driver.cpp` | New | ~400 |
| `ultralight/vulkan/ultralight_gpu_driver.h` | New | ~40 |
| `ultralight/vulkan/shaders/fill.frag.glsl` | New (from SDK) | ~50 |
| `ultralight/producer/ultralight_producer.cpp` | Modify | ~50 |
| `ultralight/CMakeLists.txt` | Modify | ~20 |
| `core/frame/frame.h` | Modify (optional GPU texture) | ~10 |
| `accelerator/vulkan/image/image_mixer.cpp` | Modify (skip upload) | ~10 |

**Estimated total: ~600 new lines, ~90 modified lines.**

## Dependencies

- PR #1677 merged (provides `vulkan::device`, `vulkan::texture`)
- Ultralight SDK with GPUDriver headers
- `glslangValidator` or `shaderc` in build environment
- Vulkan 1.3 capable GPU (or MoltenVK on macOS)

## Risk assessment

| Risk | Mitigation |
|---|---|
| PR #1677 API changes before merge | Pin to specific commit |
| Thread affinity conflicts | Shared device, separate command pools |
| SPIR-V shader compatibility | Test with reference AppCore shaders |
| MoltenVK Vulkan 1.3 gaps | Runtime feature detection |
| mutable_frame GPU texture change | Opt-in, default CPU path unchanged |

## Timeline

| Phase | Prerequisite | Effort |
|---|---|---|
| 1: Vulkan GPUDriver | PR #1677 merged | 3-5 days |
| 2: CPU fallback | Phase 1 | 1 day |
| 3: macOS via MoltenVK | Phase 1 + macOS build | 1-2 days |
