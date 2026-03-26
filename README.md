# CasparCG Offline Rendering

Fork of [CasparCG Server](https://github.com/CasparCG/server) with support for
faster-than-real-time offline rendering of video + HTML graphics.

Built by [Den Frie Vilje](https://denfrievilje.dk).

## What this adds

### Offline Consumer

A new consumer that renders composited output to file as fast as the CPU/GPU
allows. No real-time synchronisation — the pipeline applies back-pressure
automatically via a bounded frame queue.

```
ADD 1 OFFLINE /output/render.mp4 -codec:v libx264 -preset:v fast -crf:v 18 -codec:a aac
```

### Ultralight HTML Producer

A synchronous WebKit-based HTML renderer that advances exactly one frame per
channel tick. Deterministic at any speed — no wall-clock dependency.

Templates use the same CG protocol as CEF (`play()`, `stop()`, `update()`).
Both producers inject a deterministic JS API:

```js
window.__caspar_frame    // integer frame count (0-indexed)
window.__caspar_time     // virtual time in seconds
window.__caspar_tick(f)  // called once per channel tick
window.__caspar_producer // 'cef' or 'ultralight'
```

### Performance

Measured in Docker on macOS (software GL, 720p25). Native Linux with GPU
will be faster.

| Configuration              | Speed | Frames | Deterministic |
|----------------------------|-------|--------|---------------|
| Video only (offline)       | 2.3x  | 501    | +1            |
| Video + Ultralight offline | 1.5x  | 500    | exact         |
| Video + CEF offline        | 1.5x  | 500    | No*           |
| FFmpeg consumer (any)      | 0.9x  | 501    | +1            |

*CEF renders asynchronously at wall-clock speed. In offline mode the overlay
frames are duplicated/skipped. Use Ultralight for deterministic rendering.*

## Repository structure

```
casparCG/
├── server/          git submodule (den-frie-vilje/server)
├── client/          git submodule (den-frie-vilje/client)
├── tests/           Dockerfiles, test scripts, media, templates
├── docs/            Architecture and design documentation
├── AGENT.md         Development conventions and workarounds
└── docker-compose.yml
```

## Quick start

```bash
# Clone with submodules
git clone --recurse-submodules https://github.com/den-frie-vilje/casparCG.git
cd casparCG

# Build the Docker images
docker compose build

# Run the 2x2 matrix test (CEF/Ultralight x FFmpeg/Offline)
./tests/test_matrix.sh

# Run the precise render test (frame-accurate verification)
./tests/test_precise_render.sh
```

### Generate test media

The test video is tracked in LFS. To regenerate it:

```bash
./tests/generate_test_media.sh
```

Requires ffmpeg and the Inter / JetBrains Mono fonts (the script downloads them).

## Building from source

The server submodule is on the `feature/offline-rendering-ultralight` branch.
See [docs/offline-rendering.md](docs/offline-rendering.md) for the offline
consumer and [docs/ultralight-producer.md](docs/ultralight-producer.md) for
the Ultralight producer.

```bash
cd server
cmake -GNinja src \
  -DENABLE_ULTRALIGHT=ON \
  -DULTRALIGHT_SDK_PATH=/opt/ultralight-sdk
cmake --build .
```

Ultralight is optional (`ENABLE_ULTRALIGHT=OFF` by default). The offline
consumer works without it.

## AMCP usage

```
# Pre-load video and template
LOAD 1-1 my_video
CG 1-10 ADD 0 my_template 0

# Atomic start
BEGIN
PLAY 1-1
CG 1-10 PLAY 0
ADD 1 OFFLINE /output/render.mp4 -codec:v libx264 -crf:v 18 -codec:a aac
COMMIT

# Wait for video to finish, then remove consumer
REMOVE 1 OFFLINE /output/render.mp4
```

The `BEGIN`/`COMMIT` block ensures video, template, and consumer start on the
same channel tick.

## Blast radius

44 lines modified across 8 existing CasparCG source files. All new code is
self-contained in new files or gated behind `ENABLE_ULTRALIGHT`.

See [docs/architecture.md](docs/architecture.md) for the full CasparCG
architecture documentation.

## Documentation

- [Architecture](docs/architecture.md) — CasparCG internals with Mermaid diagrams
- [Offline Consumer](docs/offline-rendering.md) — design and back-pressure mechanism
- [Ultralight Producer](docs/ultralight-producer.md) — synchronous renderer + GPU roadmap
- [Vulkan Migration](docs/ultralight-vulkan-migration.md) — plan for Vulkan 1.3 integration
- [GPU on macOS Docker](docs/gpu-acceleration-macos-docker.md) — research findings

## License

CasparCG Server is licensed under the GNU General Public License v3.
Ultralight is proprietary (free for non-commercial use) and is NOT bundled —
users download the SDK separately.
