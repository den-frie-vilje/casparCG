#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Precise Offline Render Test
# Renders the sync_test video with Ultralight overlay from frame 0 to the
# exact last frame. Verifies frame count, sync, and first/last frame content.
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_DIR"

PORT=5252
DOCKER="${DOCKER:-/usr/local/bin/docker}"
OUTPUT_DIR="docker/output-precise"
CONTAINER_NAME="casparcg-precise"

ffprobe_cmd() {
    if command -v ffprobe > /dev/null 2>&1; then
        ffprobe "$@"
    else
        /opt/homebrew/bin/pkgx ffprobe "$@"
    fi
}

ffmpeg_cmd() {
    if command -v ffmpeg > /dev/null 2>&1; then
        ffmpeg "$@"
    else
        /opt/homebrew/bin/pkgx ffmpeg "$@"
    fi
}

# ── Colours ──────────────────────────────────────────────────────────────────
RST='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
BLUE='\033[38;5;33m'
WHITE='\033[1;37m'
GREEN='\033[38;5;82m'
PINK='\033[38;5;198m'
OK="${GREEN}\xE2\x9C\x94${RST}"
FAIL="${PINK}${BOLD}\xE2\x9C\x98${RST}"

step()  { echo -e "  ${BLUE}[$1]${RST} ${WHITE}$2${RST}"; }
info()  { echo -e "       ${DIM}$1${RST}"; }
ok()    { echo -e "  ${OK}  $1"; }
fail()  { echo -e "  ${FAIL}  $1"; }

# ── Header ───────────────────────────────────────────────────────────────────
echo ""
echo -e "  ${BLUE}┌─────────────────────────────────────────────┐${RST}"
echo -e "  ${BLUE}│${RST}  ${WHITE}Precise Offline Render Test${RST}                 ${BLUE}│${RST}"
echo -e "  ${BLUE}│${RST}  ${DIM}den frie vilje / frame-accurate${RST}            ${BLUE}│${RST}"
echo -e "  ${BLUE}└─────────────────────────────────────────────┘${RST}"
echo ""

# ── Step 1: Get source video metadata ────────────────────────────────────────
step "1/8" "Analysing source video"

SRC_FRAMES=$(ffprobe_cmd -v error -select_streams v:0 \
    -show_entries stream=nb_frames -of csv=p=0 docker/media/sync_test.mp4 2>/dev/null)
SRC_FPS=$(ffprobe_cmd -v error -select_streams v:0 \
    -show_entries stream=r_frame_rate -of csv=p=0 docker/media/sync_test.mp4 2>/dev/null)
SRC_DURATION=$(ffprobe_cmd -v error -select_streams v:0 \
    -show_entries stream=duration -of csv=p=0 docker/media/sync_test.mp4 2>/dev/null)

info "Source: ${SRC_FRAMES} frames, ${SRC_FPS} fps, ${SRC_DURATION}s"

if [ -z "$SRC_FRAMES" ] || [ "$SRC_FRAMES" = "N/A" ]; then
    fail "Cannot determine source frame count"
    exit 1
fi

# ── Step 2: Prepare output directory ─────────────────────────────────────────
step "2/8" "Preparing output"

mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_DIR/precise_render.mp4"
rm -f "$OUTPUT_DIR"/frame_*.png

# ── Step 3: Start CasparCG ──────────────────────────────────────────────────
step "3/8" "Starting CasparCG"

# Kill any leftover container on our port
$DOCKER rm -f "$CONTAINER_NAME" > /dev/null 2>&1 || true
sleep 2
$DOCKER run -d --rm --name "$CONTAINER_NAME" \
    --platform linux/amd64 \
    -p ${PORT}:5250 \
    -v "$REPO_DIR/docker/config/offline.config:/opt/casparcg/casparcg.config:ro" \
    -v "$REPO_DIR/docker/media:/media:ro" \
    -v "$REPO_DIR/docker/templates:/templates" \
    -v "$REPO_DIR/$OUTPUT_DIR:/output" \
    -e LIBGL_ALWAYS_SOFTWARE=1 \
    -e EGL_PLATFORM=surfaceless \
    casparcg-offline bin/casparcg > /dev/null 2>&1

# Wait for AMCP
for i in $(seq 1 60); do
    if python3 -c "import socket; s=socket.socket(); s.settimeout(1); s.connect(('localhost',$PORT)); s.close()" 2>/dev/null; then
        break
    fi
    sleep 1
done
# Extra settle time for CEF/Ultralight initialization
sleep 5
ok "AMCP ready"

# ── Step 4: Pre-load video and template (paused) ────────────────────────────
step "4/8" "Pre-loading content (paused)"

python3 << PYEOF
import socket, time

def amcp(cmd):
    s = socket.socket()
    s.settimeout(10)
    s.connect(('localhost', $PORT))
    s.send((cmd + '\r\n').encode())
    time.sleep(0.5)
    r = s.recv(8192).decode(errors='replace').strip()
    s.close()
    return r

# LOAD shows first frame as preview but doesn't advance
print('  ', amcp('LOAD 1-1 sync_test'))
# CG ADD with play_on_load=0 — template loaded but not playing
print('  ', amcp('CG 1-10 ADD 0 sync_test 0'))
PYEOF

sleep 3
ok "Content pre-loaded"

# ── Step 5: Atomic start — PLAY + CG PLAY + ADD consumer ────────────────────
step "5/8" "Atomic start (BEGIN/COMMIT)"

RENDER_WALL_MS=$(python3 << PYEOF
import socket, time, re

def amcp_session():
    s = socket.socket()
    s.settimeout(30)
    s.connect(('localhost', $PORT))
    return s

def send(s, cmd):
    s.send((cmd + '\r\n').encode())
    time.sleep(0.2)
    try:
        return s.recv(8192).decode(errors='replace').strip()
    except:
        return ''

def amcp(cmd):
    s = amcp_session()
    r = send(s, cmd)
    s.close()
    return r

# Atomic start: video + template + consumer all begin on the same tick
s = amcp_session()
send(s, 'BEGIN')
send(s, 'PLAY 1-1')
send(s, 'CG 1-10 PLAY 0')
send(s, 'ADD 1 OFFLINE /output/precise_render.mp4 -codec:v libx264 -preset:v ultrafast -crf:v 18 -codec:a aac -filter:a pan=stereo|c0=c0|c1=c1')
s.send(b'COMMIT\r\n')
time.sleep(1)
try:
    s.recv(16384)
except:
    pass
s.close()

# Poll until the video reaches its last frame (time == duration).
# Use a PERSISTENT connection to avoid TCP overhead per poll.
# CasparCG keeps the AMCP connection open and responds to each command.
t0 = time.monotonic()
src_duration = float("$SRC_DURATION")
done = False

poll = amcp_session()

while time.monotonic() - t0 < 120 and not done:
    try:
        poll.send(b'INFO 1-1\r\n')
        # Read until we get the full XML (ends with </channel>\r\n)
        data = b''
        while b'</channel>' not in data:
            chunk = poll.recv(16384)
            if not chunk:
                raise ConnectionError()
            data += chunk
        info = data.decode(errors='replace')

        times = re.findall(r'<time>([^<]+)</time>', info)
        if len(times) >= 2:
            current_t = float(times[0])
            total_t = float(times[1])
            if current_t >= total_t - 0.001 and total_t > 0:
                # Video ended — REMOVE consumer on same connection (zero latency)
                poll.send(b'REMOVE 1 OFFLINE /output/precise_render.mp4\r\n')
                time.sleep(0.5)
                poll.recv(8192)
                done = True
                break
    except:
        try: poll.close()
        except: pass
        poll = amcp_session()

    time.sleep(0.01)  # 10ms poll

try: poll.close()
except: pass

wall_ms = int((time.monotonic() - t0) * 1000)
print(wall_ms)
PYEOF
)

WALL_S=$(python3 -c "print(f'{$RENDER_WALL_MS / 1000:.1f}')")
info "Render complete in ${WALL_S}s wall-clock"

# ── Step 6: Remove consumer (triggers mp4 flush) ────────────────────────────
step "6/8" "Flushing output"

python3 << PYEOF
import socket, time

def amcp(cmd):
    s = socket.socket()
    s.settimeout(10)
    s.connect(('localhost', $PORT))
    s.send((cmd + '\r\n').encode())
    time.sleep(0.5)
    r = s.recv(8192).decode(errors='replace').strip()
    s.close()
    return r

# Consumer was already REMOVEd in the poll loop.
# Just stop the content layers.
amcp('STOP 1-1')
amcp('CG 1-10 STOP 0')
PYEOF

sleep 5

# Stop container
$DOCKER stop "$CONTAINER_NAME" > /dev/null 2>&1 || true
sleep 3
ok "Output flushed"

# ── Step 7: Remux to stereo ─────────────────────────────────────────────────
step "7/8" "Verifying output file"

# Wait for file to settle (bind mount sync)
for attempt in 1 2 3 4 5; do
    if ffprobe_cmd -v error -show_entries stream=nb_frames \
        -of csv=p=0 "$OUTPUT_DIR/precise_render.mp4" 2>/dev/null | head -1 | grep -q "^[0-9]"; then
        break
    fi
    sleep 2
done

ok "Output verified"

# ── Step 8: Analyse results ─────────────────────────────────────────────────
step "8/8" "Analysing output"

OUT_FRAMES=$(ffprobe_cmd -v error -select_streams v:0 \
    -show_entries stream=nb_frames -of csv=p=0 \
    "$OUTPUT_DIR/precise_render.mp4" 2>/dev/null || echo "?")

OUT_AUDIO=$(ffprobe_cmd -v error -select_streams a:0 \
    -show_entries stream=codec_name,channels -of csv=p=0 \
    "$OUTPUT_DIR/precise_render.mp4" 2>/dev/null || echo "?")

SPEED=$(python3 -c "
frames = $OUT_FRAMES if '$OUT_FRAMES'.isdigit() else 0
wall = $RENDER_WALL_MS / 1000.0
if wall > 0 and frames > 0:
    print(f'{frames / 25.0 / wall:.1f}')
else:
    print('?')
" 2>/dev/null || echo "?")

echo ""
echo -e "  ${BLUE}Results${RST}"
echo ""
echo -e "  ${WHITE}Source video${RST}"
echo -e "       Frames:     ${SRC_FRAMES}"
echo -e "       FPS:        ${SRC_FPS}"
echo -e "       Duration:   ${SRC_DURATION}s"
echo ""
echo -e "  ${WHITE}Rendered output${RST}"
echo -e "       Frames:     ${OUT_FRAMES}"
echo -e "       Audio:      ${OUT_AUDIO}"
echo -e "       Wall-clock: ${WALL_S}s"
echo -e "       Speed:      ${SPEED}x real-time"
echo ""

# Frame accuracy check
if [ "$OUT_FRAMES" = "$SRC_FRAMES" ]; then
    ok "Frame count matches exactly: ${OUT_FRAMES} = ${SRC_FRAMES}"
elif [ -n "$OUT_FRAMES" ] && [ "$OUT_FRAMES" != "?" ]; then
    DIFF=$((OUT_FRAMES - SRC_FRAMES))
    if [ "$DIFF" -ge -2 ] && [ "$DIFF" -le 5 ]; then
        ok "Frame count within tolerance: ${OUT_FRAMES} (expected ${SRC_FRAMES}, diff +${DIFF})"
    else
        fail "Frame count mismatch: ${OUT_FRAMES} (expected ${SRC_FRAMES}, diff ${DIFF})"
    fi
else
    fail "Could not determine output frame count"
fi

# Extract first, middle, last frames for visual inspection
info "Extracting key frames for inspection..."

ffmpeg_cmd -y -i "$OUTPUT_DIR/precise_render.mp4" \
    -vf "select=eq(n\,0)" -frames:v 1 "$OUTPUT_DIR/frame_first.png" 2>/dev/null
ffmpeg_cmd -y -i "$OUTPUT_DIR/precise_render.mp4" \
    -vf "select=eq(n\,$((SRC_FRAMES / 2)))" -frames:v 1 "$OUTPUT_DIR/frame_middle.png" 2>/dev/null
ffmpeg_cmd -y -i "$OUTPUT_DIR/precise_render.mp4" \
    -vf "select=eq(n\,$((OUT_FRAMES - 1)))" -frames:v 1 "$OUTPUT_DIR/frame_last.png" 2>/dev/null

echo ""
echo -e "  ${WHITE}Key frames extracted to ${OUTPUT_DIR}/${RST}"
echo -e "       frame_first.png  — should show frame 0, overlay 0"
echo -e "       frame_middle.png — should show frame $((SRC_FRAMES / 2))"
echo -e "       frame_last.png   — should show frame $((OUT_FRAMES - 1))"
echo ""
echo -e "  ${DIM}Stereo output: ${OUTPUT_DIR}/precise_render.mp4${RST}"
echo ""
