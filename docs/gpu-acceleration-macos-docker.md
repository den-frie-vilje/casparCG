# GPU Acceleration in Docker on macOS

<!-- Copyright (c) Den Frie Vilje (hej@denfrievilje.dk) -->

## TL;DR

**Not possible as of March 2026.** No Docker runtime on macOS exposes the GPU
to Linux containers. The recommended deployment target for GPU-accelerated
CasparCG is Linux with an NVIDIA GPU.

## Why it doesn't work

Docker Desktop on macOS runs Linux containers inside a lightweight VM using
Apple's Hypervisor.framework. This framework provides virtual CPUs and memory
but **does not expose any virtual GPU** to guests. Apple has not added GPU
virtualisation to this framework.

Docker's official GPU support covers only NVIDIA GPUs on Linux and Windows
(via WSL2). macOS is explicitly excluded with no public roadmap.

## Alternative runtimes evaluated

| Runtime | GPU Support | Notes |
|---|---|---|
| Docker Desktop | No | No roadmap |
| OrbStack | No | Open feature requests, no implementation |
| Apple Containerization (WWDC 2025) | No | VM-per-container model makes GPU sharing difficult |
| Podman + libkrun | **Vulkan only** | Experimental, broke with Podman 5.0+ |
| Colima + krunkit | **Vulkan only** | Same libkrun stack as Podman |

### Podman + libkrun (most promising, still impractical)

Podman with the `libkrun` VM backend can expose a Vulkan pipeline:

```
Container: Vulkan API -> Venus protocol -> virglrenderer (host) -> MoltenVK -> Metal -> Apple GPU
```

CasparCG needs **OpenGL 4.5 compatibility profile**, not Vulkan. Running
OpenGL on top of this requires Mesa's Zink driver (OpenGL-over-Vulkan),
adding a double translation layer:

```
OpenGL 4.5 -> Zink -> Vulkan -> Venus -> MoltenVK -> Metal
```

This is fragile, slow (~50-70% native), and Zink's compatibility profile
support is incomplete.

### Apple Virtualization.framework

- Supports only **2D virtio-gpu** for Linux guests
- "Paravirtualised Graphics" targets macOS guests only
- QEMU + HVF can get limited 3D via virglrenderer, but for full VMs not Docker

## What works today

| Approach | Performance | Use case |
|---|---|---|
| llvmpipe (current) | ~5-10% of GPU | Development/testing only |
| Linux + NVIDIA GPU | ~100% | Production |
| Cloud GPU (AWS G4/G5) | ~100% + latency | Non-live / NDI workflows |

## Recommended deployment

**Production:** Dedicated Linux machine with NVIDIA GPU. Use Docker with
`nvidia-container-toolkit`. Control remotely from macOS via CasparCG Client,
SuperConductor, or SPX-GC over the network.

**Development:** Continue using `LIBGL_ALWAYS_SOFTWARE=1` with llvmpipe.
Accept the performance limitation for local iteration.

**Cloud:** AWS EC2 G4/G5 or Azure NV-series for burst rendering.

## Future developments to watch

1. **CasparCG Vulkan backend** ([PR #1677](https://github.com/CasparCG/server/pull/1677),
   [casparcgvulkan.com](https://www.casparcgvulkan.com/)) — if this ships,
   Podman + libkrun becomes viable on macOS (no Zink needed).

2. **Apple Virtualization.framework** — if Apple adds virtio-gpu 3D support,
   all container runtimes benefit immediately.

3. **CasparCG issue #937** (OpenGL core profile) — if merged, broadens
   hardware compatibility and removes the compatibility profile dependency
   that blocks Zink.

4. **Podman/libkrun stabilisation** — the Vulkan passthrough works but broke
   with Podman 5.0. Needs upstream fixes.
