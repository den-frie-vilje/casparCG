# Agent Notes — CasparCG Offline Rendering

> **This file must be kept current.** Update it whenever you discover a new
> workaround, gotcha, or architectural decision. Also keep `docs/architecture.md`,
> `docs/offline-rendering.md`, `docs/ultralight-producer.md`, and `README.md` in
> sync with any changes.

---

## Docker Build

### Cache busting for source changes

Docker's layer cache doesn't always detect content changes in `COPY ./server/src /source`
(especially after `touch` or metadata-only changes). The Dockerfile uses a `SOURCE_HASH`
build arg to force invalidation:

```bash
SRC_HASH=$(find server/src -name '*.cpp' -o -name '*.h' | sort | xargs shasum | shasum | cut -c1-12)
docker build --build-arg SOURCE_HASH="$SRC_HASH" -f tests/Dockerfile.offline -t casparcg-offline .
```

Without this, you may get a stale binary even after editing source files.

### ALWAYS use --progress=plain

Docker BuildKit's default progress display swallows all compiler output. When a
build fails, you only see `exit code: 1` with zero indication of what went wrong.
This has wasted significant time repeatedly.

**Always build with:**
```bash
docker build --progress=plain -f tests/Dockerfile.offline -t casparcg-offline . 2>&1 | tee /tmp/build.log
```

To find errors in the log: `grep "error:" /tmp/build.log`

### Apt mirror flakiness

The Ubuntu Noble (`buildpack-deps:noble`) apt mirrors fail intermittently with exit code 100.
`--no-cache` builds are especially vulnerable because they re-download everything.
Workaround: retry, or use cached apt layers (only `--no-cache` the source/build steps).

### Disk space

A full `--no-cache` build of CasparCG + CEF + Ultralight needs ~15GB of build cache.
Run `docker system prune -af && docker builder prune -af` before large rebuilds.

---

## CasparCG Audio

### 16-channel output

CasparCG hardcodes `audio_channels = 16` in `video_format.h`. The `-ac 2` flag in
AMCP ADD commands is ignored because the filter graph is built with 16 channels.

**Solution:** Use `-filter:a pan=stereo|c0=c0|c1=c1` in the AMCP ADD command to
downmix to stereo at encode time. No post-processing needed.

```
ADD 1 OFFLINE /output/file.mp4 -codec:v libx264 -codec:a aac -filter:a pan=stereo|c0=c0|c1=c1
```

The FFmpeg consumer's `Stream` class parses `-filter:a` into the audio filter graph,
replacing the default `anull` filter with the `pan` filter.

---

## Ultralight Producer

### File loading and asset resolution

The AppCore `GetPlatformFileSystem()` crashes with `file://` URLs in headless Docker
containers. Both `LoadURL("file:///...")` and `LoadHTML(content, base_url)` triggered
SIGSEGV when using the AppCore filesystem.

**Solution:** We implement a custom `caspar_file_system` class that inherits from
`ul::FileSystem` and does plain POSIX file I/O via `std::ifstream`. This replaces
`GetPlatformFileSystem()` entirely.

The custom FileSystem:
- Uses `boost::filesystem::exists()` for cross-platform path checking
- Uses `caspar::find_case_insensitive()` for Linux case-sensitivity
- Returns 16-byte aligned buffers (required for ICU data files)
- Handles MIME type detection from file extensions
- Guards against empty files (`size == 0`)

Templates are loaded via `LoadURL("file:///templates/foo.html")`. Ultralight calls
our `FileExists()` and `OpenFile()` with the path after `file:///` (e.g.
`/templates/foo.html`). Relative assets (images, CSS, fonts referenced in the HTML)
resolve against the template's directory automatically.

**HTTP URLs:** `LoadURL("https://...")` should work via Ultralight's built-in network
stack, bypassing our FileSystem entirely. Not yet tested.

**Key:** `file:///` (triple slash) = absolute path from filesystem root.
The FileSystem methods receive the path portion without the `file://` scheme prefix.

**IMPORTANT:** Ultralight strips the leading `/` from `file:///` URLs before passing
to FileSystem. So `file:///templates/foo.html` arrives as `templates/foo.html` (relative),
not `/templates/foo.html` (absolute). Our `resolve_path()` prepends `/` to make it
absolute. This is a quirk of Ultralight's URL parser, not a bug in our code.

### Thread affinity

All Ultralight API calls (Renderer::Create, Update, Render, View methods) must happen
on the same thread. CasparCG's `call()` method (for CG PLAY/STOP/UPDATE) is invoked
from the AMCP protocol thread, not the channel tick thread.

**Workaround:** `call()` only sets flags and queues JS strings. The actual Ultralight
API calls happen in `receive_impl()` which runs on the channel tick thread. A
`pending_js_` queue and `playing_` atomic flag bridge the two threads.

### Platform singleton

`ul::Platform::instance().set_config()` must be called exactly once globally.
Multiple Ultralight producers (different channels/resolutions) share the singleton.

**Workaround:** Use `std::call_once` to initialize the Platform on first use.
Each producer gets its own `Renderer` and `View` (these are per-instance, not global).

### Asset loading (fonts, images)

With `LoadURL`, relative paths like `src="dfv_logo.png"` or
`@font-face { src: url('Font.ttf') }` resolve against the template's directory.
Assets must be in the same directory as the template (or use absolute/full paths).

For HTTP URLs, assets resolve against the remote server as expected.

---

## CEF Producer

### Frame drift in offline mode

CEF's `requestAnimationFrame` runs on its own wall-clock timer, not the CasparCG
channel tick. In offline mode (faster than real-time), the overlay frame counter
drifts from the video.

**Workaround:** Inject `window.__caspar_frame` via `ExecuteJavaScript` on each
`receive()` call. Templates that read this variable get the correct frame number.
However, the actual CEF paint still happens on CEF's own schedule — the injected
value may be 1-2 frames ahead of what's painted. For deterministic rendering,
use the Ultralight producer instead.

### CEF cannot render faster than real-time

CEF's compositor is wall-clock driven. `SendExternalBeginFrame()` doesn't reliably
speed it up. In offline mode, CEF templates repeat frames (the `still(last_frame_)`
path). The channel ticks faster than CEF paints.

**No workaround within CEF.** This is a fundamental limitation. Use Ultralight for
offline rendering that needs frame-accurate template sync.

---

## Offline Consumer

### REMOVE command required for mp4 flush

The offline consumer writes the mp4 moov atom in its destructor. If the container
is killed (SIGTERM/SIGKILL) before the destructor runs, the file has no moov atom
and is unplayable.

**Workaround:** Always send `REMOVE 1 OFFLINE /output/file.mp4` via AMCP before
stopping the container. The REMOVE triggers the flush. Wait for the file size to
stabilize before stopping Docker.

### Speed measurement

The offline consumer resolves `send()` futures immediately (no sync clock), so the
channel ticks as fast as the encoder allows. Measuring speed requires millisecond-
precision timing (not `date +%s` which has 1s granularity).

**Workaround:** Use `time.monotonic()` in Python for wall-clock measurement.
Include the REMOVE + flush time in the measurement for honest benchmarks.

---

## Test Video Generation

### CRLF line endings

The `Write` tool on macOS sometimes produces CRLF line endings in shell scripts.
This causes `env: bash\r: No such file or directory`.

**Workaround:** Run `sed -i '' 's/\r$//' script.sh` after writing any new shell script.

### Font availability

The test video uses JetBrains Mono for monospaced frame counters. The font must be
downloaded to `/tmp/jetbrains-mono/` before running `generate_sync_test.sh`.
Inter is used for UI labels and must be at `/tmp/inter-font/`.

### ffmpeg pan filter limitations

The `pan` filter cannot use `if()` expressions in channel mapping. For alternating
L/R audio bleeps, use `asplit` → two `volume` filters with gating expressions →
`join` to recombine into stereo.

---

## AMCP Protocol

### BEGIN/COMMIT for atomic playback start

To start video + CG template + consumer simultaneously:

```
BEGIN
PLAY 1-1
CG 1-10 PLAY 0
ADD 1 OFFLINE /output/file.mp4 ...
COMMIT
```

All commands execute on the same channel tick. Send on a single TCP connection.
The COMMIT response includes all individual responses.

### Consumer REMOVE syntax

Bare `REMOVE 1` doesn't work. Use the full form with consumer type and path:

```
REMOVE 1 OFFLINE /output/file.mp4
REMOVE 1 FILE /output/file.mp4
```

---

## File Locations

| What | Path |
|------|------|
| Offline consumer source | `server/src/modules/ffmpeg/consumer/offline_consumer.cpp` |
| Ultralight producer source | `server/src/modules/ultralight/producer/ultralight_producer.cpp` |
| CEF frame injection | `server/src/modules/html/producer/html_producer.cpp` |
| Docker build | `tests/Dockerfile.offline` |
| CasparCG config | `tests/config/offline.config` |
| Test video generator | `tests/generate_sync_test.sh` |
| Matrix benchmark | `tests/test_matrix.sh` |
| Overlay template | `tests/templates/sync_test.html` |
| Architecture docs | `server/docs/architecture.md` |
| Offline rendering docs | `server/docs/offline-rendering.md` |
| Ultralight docs | `server/docs/ultralight-producer.md` |

---

## CasparCG Coding Conventions

Follow these conventions in all new code to match the existing codebase.

### Naming
- **Classes**: `snake_case` (e.g. `html_producer`, `offline_consumer`)
- **Methods**: `snake_case` (e.g. `receive_impl`, `try_pop`)
- **Member variables**: `snake_case_` with trailing underscore
- **Local variables**: `snake_case` without trailing underscore
- **Namespaces**: nested `namespace caspar { namespace module {`, closing `}} // namespace caspar::module`

### Includes (in order, separated by blank lines)
1. Own header (`#include "my_class.h"`)
2. Module-relative (`../util/av_assert.h`)
3. `<core/...>`
4. `<common/...>`
5. `<boost/...>`
6. Third-party (TBB, CEF, FFmpeg, Ultralight)
7. Standard library (`<mutex>`, `<thread>`, `<string>`)

### Error handling
- `CASPAR_THROW_EXCEPTION(type() << msg_info("message"))`
- `CASPAR_LOG_CURRENT_EXCEPTION()` in catch blocks
- `CASPAR_SCOPE_EXIT { ... }` for resource cleanup

### Logging
- `CASPAR_LOG(level) << print() << L" message";`
- Levels: `debug`, `info`, `warning`, `error`, `fatal`
- Wide strings (`L"..."`) in log messages
- `print()` returns `L"type[identifier]"` (e.g. `L"ultralight[" + url_ + L"]"`)

### Memory
- `spl::shared_ptr<T>` for core types (non-null)
- `std::shared_ptr<T>` for nullable/external types
- No raw `new`/`delete` — RAII via smart pointers
- Lambda deleters for C-style cleanup

### Threading
- `std::mutex` + `std::lock_guard<std::mutex>`
- `std::atomic<bool>` for simple flags
- `tbb::concurrent_bounded_queue` for producer-consumer patterns
- All Ultralight API calls on the channel tick thread (never AMCP thread)

### Lifecycle (producers)
- Constructor: set up state, register graph
- `receive_impl()`: produce frames (called on tick thread)
- `call()`: handle AMCP commands (called on protocol thread — queue, don't execute)
- Destructor: clean up resources

### Lifecycle (consumers)
- Constructor: set up state, register graph
- `initialize()`: start encoder thread
- `send()`: push frames to queue
- Destructor: push EOS sentinel, join thread

### Copyright header (required on all files)
```
/*
 * Copyright (c) 2011 Sveriges Television AB <info@casparcg.com>
 * Copyright (c) 2025 Den Frie Vilje ApS <hej@denfrievilje.dk>
 * ... GPL v3 boilerplate ...
 * Author: Name, email
 */
```

### Boost vs std
- `boost::filesystem` (not `std::filesystem`)
- `boost::algorithm::string` for string ops
- `std::mutex`, `std::thread`, `std::atomic`, `std::optional` from stdlib
- `u8()` / `u16()` from `common/utf.h` for string conversion
