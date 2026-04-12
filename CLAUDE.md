# CLAUDE.md

This file is the entry point for any agent starting work on this repository.
Read it before doing anything else.

---

## What this project is

This is a fork of [CasparCG Server](https://github.com/CasparCG/server) that
adds faster-than-real-time offline rendering of video and HTML graphics. The
two main additions are an offline consumer (renders to file as fast as the
CPU/GPU allows) and an Ultralight HTML producer (a synchronous, deterministic
WebKit-based renderer that advances one frame per channel tick).

The project is maintained by Den Frie Vilje ApS. It is GPL v3 licensed.
Ultralight is proprietary but not bundled; it must be downloaded separately.

---

## Shared organisational context

For design principles, role definitions, and coordination protocols, see
https://github.com/den-frie-vilje/agentic-org

In particular:
- `DESIGN.md` governs visual and editorial decisions
- `PRINCIPLES.md` governs architectural and dependency choices
- `context/project-registry.md` describes where this project fits in the
  Den Frie Vilje portfolio

All changes to this repository follow the same issue-to-PR-to-merge cycle
described in agentic-org's `CLAUDE.md`. No direct commits to `main`.

---

## Architecture overview

CasparCG is a professional broadcast playout engine. Frames flow from
producers through the stage and mixer to consumers. The key components:

- `server/src/core/` -- stage, mixer, output. The frame pipeline.
- `server/src/modules/ffmpeg/` -- FFmpeg producer and file consumer
- `server/src/modules/html/` -- CEF-based HTML producer (not deterministic
  in offline mode)
- `server/src/modules/ultralight/` -- Ultralight HTML producer (deterministic,
  one frame per tick; use this for offline rendering with templates)
- `server/src/modules/ffmpeg/consumer/offline_consumer.cpp` -- the offline
  consumer. Renders to file with no real-time synchronisation.
- `tests/` -- Docker-based test infrastructure, benchmark scripts, templates

The Ultralight producer injects a deterministic JS API into every template:
`window.__caspar_frame`, `window.__caspar_time`, `window.__caspar_tick(f)`.
Templates should use these instead of `Date.now()` or `requestAnimationFrame`.

See `docs/architecture.md` for the full pipeline diagram and threading model.

---

## Files to read before making any change

1. `AGENT.md` -- development conventions, gotchas, and workarounds. This is
   the most important file for day-to-day work. Read it first.
2. `docs/architecture.md` -- high-level architecture and frame pipeline
3. `docs/offline-rendering.md` -- offline consumer design and usage
4. `docs/ultralight-producer.md` -- Ultralight producer design and JS API
5. `docs/ultralight-vulkan-migration.md` -- planned Vulkan GPU migration

---

## Building and testing

The project builds inside Docker. The test infrastructure is in `tests/`.

```bash
# Build the offline-capable image
SRC_HASH=$(find server/src -name '*.cpp' -o -name '*.h' | sort | xargs shasum | shasum | cut -c1-12)
docker build --progress=plain --build-arg SOURCE_HASH="$SRC_HASH"   -f tests/Dockerfile.offline -t casparcg-offline .

# Run the benchmark matrix
bash tests/test_matrix.sh
```

Always use `--progress=plain` on Docker builds. BuildKit's default display
swallows all compiler output. See `AGENT.md` for details on why.

---

## Conventions

C++ conventions are documented in `AGENT.md` under "CasparCG Coding
Conventions". Follow them in all new code.

Key points:
- `snake_case` for classes, methods, and variables; trailing `_` for members
- `spl::shared_ptr<T>` for non-null core types, `std::shared_ptr<T>` otherwise
- `boost::filesystem` not `std::filesystem`
- All Ultralight API calls must be on the channel tick thread, not the AMCP
  protocol thread (see `AGENT.md` for the threading constraint)
- Copyright header required on all new files (see `AGENT.md`)

---

## Known issues and deferred work

- Vulkan 1.3 GPU acceleration for Ultralight is planned. See
  `docs/ultralight-vulkan-migration.md`. Not yet started.
- CEF cannot render faster than real-time in offline mode. This is a
  fundamental CEF limitation. Use Ultralight for deterministic offline
  rendering.
- The offline consumer's mp4 moov atom is only written on clean shutdown.
  Always send `REMOVE 1 OFFLINE /output/file.mp4` before stopping the
  container.

---

## Licence

Server code: GNU GPL v3. See `server/LICENSE`.
Ultralight: proprietary, free for non-commercial use. Not bundled; must be
downloaded separately. Do not distribute Ultralight binaries.
