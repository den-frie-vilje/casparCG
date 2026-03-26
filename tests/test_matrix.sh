#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# 2x2 Matrix Test — CEF/Ultralight × FFmpeg/Offline (Serial)
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_DIR"

PORT=5252
DOCKER="${DOCKER:-/usr/local/bin/docker}"

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

RST='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'
BLUE='\033[38;5;33m'; WHITE='\033[1;37m'; GREEN='\033[38;5;82m'
PINK='\033[38;5;198m'
OK="${GREEN}✔${RST}"; FAIL="${PINK}${BOLD}✘${RST}"

step()  { echo -e "  ${BLUE}$1${RST} ${WHITE}$2${RST}"; }
ok()    { echo -e "  ${OK}  $1"; }
fail()  { echo -e "  ${FAIL}  $1"; }
info()  { echo -e "       ${DIM}$1${RST}"; }

echo ""
echo -e "  ${BLUE}┌─────────────────────────────────────────────┐${RST}"
echo -e "  ${BLUE}│${RST}  ${WHITE}2x2 Matrix: CEF/UL x FFmpeg/Offline${RST}        ${BLUE}│${RST}"
echo -e "  ${BLUE}│${RST}  ${DIM}den frie vilje / serial benchmark${RST}          ${BLUE}│${RST}"
echo -e "  ${BLUE}└─────────────────────────────────────────────┘${RST}"
echo ""

OUTPUT_DIR="docker/output-matrix"
# Remove only the specific output files we'll create (don't nuke the whole dir)
rm -f "$OUTPUT_DIR"/ch1_*.mp4 "$OUTPUT_DIR"/ch2_*.mp4 "$OUTPUT_DIR"/ch3_*.mp4 "$OUTPUT_DIR"/ch4_*.mp4
mkdir -p "$OUTPUT_DIR"

CONTAINER_NAME="casparcg-matrix"
CONFIG="$REPO_DIR/docker/config/offline.config"

# ── AMCP helpers ─────────────────────────────────────────────────────────────

amcp() {
    python3 -c "
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(10)
s.connect(('localhost', $PORT))
s.send(b'$1\r\n')
time.sleep(0.3)
print(s.recv(8192).decode(errors='replace').strip())
s.close()
" 2>/dev/null || true
}

amcp_batch() {
    python3 << PYEOF
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(15)
s.connect(('localhost', $PORT))
for cmd in $1:
    s.send((cmd + '\r\n').encode())
    time.sleep(0.15)
time.sleep(1)
data = b''
try:
    while True:
        chunk = s.recv(8192)
        if not chunk: break
        data += chunk
except: pass
s.close()
for line in data.decode(errors='replace').strip().split('\r\n'):
    if line.strip(): print('       ' + line.strip())
PYEOF
}

wait_for_amcp() {
    local max=60 waited=0
    while ! python3 -c "import socket; s=socket.socket(); s.settimeout(1); s.connect(('localhost',$PORT)); s.close()" 2>/dev/null; do
        sleep 1; waited=$((waited+1))
        if [ $waited -ge $max ]; then fail "AMCP timeout"; return 1; fi
    done
}

start_server() {
    # Kill any leftover container from a previous run
    $DOCKER rm -f "$CONTAINER_NAME" > /dev/null 2>&1 || true
    sleep 1

    $DOCKER run -d --rm --name "$CONTAINER_NAME" \
        --platform linux/amd64 \
        -p ${PORT}:5250 \
        -v "$CONFIG:/opt/casparcg/casparcg.config:ro" \
        -v "$REPO_DIR/docker/media:/media:ro" \
        -v "$REPO_DIR/docker/templates:/templates" \
        -v "$REPO_DIR/$OUTPUT_DIR:/output" \
        -e LIBGL_ALWAYS_SOFTWARE=1 \
        -e EGL_PLATFORM=surfaceless \
        casparcg-offline bin/casparcg > /dev/null 2>&1

    wait_for_amcp
    sleep 8
}

# ── Run a single render ──────────────────────────────────────────────────────
# Args: $1=label $2=filename $3=producer_type(cef|ul) $4=consumer_type(ffmpeg|offline)
run_test() {
    local label="$1" filename="$2" prod="$3" cons="$4"
    local duration=20 target=500

    step "[$TEST_NUM/4]" "$label"

    start_server

    # Load video in preview mode (paused at frame 0)
    amcp "LOAD 1-1 sync_test" > /dev/null

    # Load template via the right producer
    if [ "$prod" = "cef" ]; then
        amcp "PLAY 1-20 [HTML] sync_test" > /dev/null
        info "Template: CEF (via [HTML] prefix)"
    else
        amcp "CG 1-10 ADD 0 sync_test 0" > /dev/null
        info "Template: Ultralight (via CG registry)"
    fi

    sleep 4

    # Determine consumer ADD command
    local cons_cmd
    if [ "$cons" = "offline" ]; then
        cons_cmd="ADD 1 OFFLINE /output/${filename}.mp4 -codec:v libx264 -preset:v ultrafast -crf:v 18 -codec:a aac -filter:a pan=stereo|c0=c0|c1=c1"
    else
        cons_cmd="ADD 1 FILE /output/${filename}.mp4 -codec:v libx264 -preset:v ultrafast -crf:v 18 -codec:a aac -filter:a pan=stereo|c0=c0|c1=c1"
    fi

    # Atomic start
    local batch_cmds
    if [ "$prod" = "cef" ]; then
        batch_cmds="['BEGIN','PLAY 1-1','${cons_cmd}','COMMIT']"
    else
        batch_cmds="['BEGIN','PLAY 1-1','CG 1-10 PLAY 0','${cons_cmd}','COMMIT']"
    fi
    amcp_batch "$batch_cmds"

    # Render + flush: measure total wall-clock including I/O
    local wall_ms
    local mp4_path="$OUTPUT_DIR/${filename}.mp4"

    wall_ms=$(python3 << PYEOF
import socket, time, re, os

PORT = $PORT
target = $target
duration = $duration
cons = "$cons"
mp4_path = "$mp4_path"

t0 = time.monotonic()

if cons == "offline":
    # Poll until frame target reached
    print("offline_poll", file=__import__('sys').stderr)
    while time.monotonic() - t0 < 60:
        time.sleep(0.2)
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(2)
            s.connect(('localhost', PORT))
            s.send(b'INFO 1\r\n')
            time.sleep(0.2)
            data = s.recv(16384).decode(errors='replace')
            s.close()
            m = re.search(r'<frame>(\d+)</frame>', data)
            if m and int(m.group(1)) >= target:
                break
        except:
            pass
else:
    # FFmpeg: real-time, just wait
    time.sleep(duration + 2)

# STOP + REMOVE (flush the mp4 trailer)
def amcp_cmd(cmd):
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(5)
        s.connect(('localhost', PORT))
        s.send((cmd + '\r\n').encode())
        time.sleep(0.3)
        s.recv(4096)
        s.close()
    except:
        pass

amcp_cmd('STOP 1-1')
if cons == "offline":
    amcp_cmd('REMOVE 1 OFFLINE /output/${filename}.mp4')
else:
    amcp_cmd('REMOVE 1 FILE /output/${filename}.mp4')

# Wait for file to stabilize (moov atom written)
prev_size = 0
for _ in range(15):
    time.sleep(0.5)
    try:
        cur_size = os.path.getsize(mp4_path)
        if cur_size == prev_size and cur_size > 0:
            break
        prev_size = cur_size
    except:
        pass

# Total wall-clock: render + encode + flush
print(int((time.monotonic() - t0) * 1000))
PYEOF
)
    if [ "$cons" = "offline" ]; then
        info "Offline: render + flush complete"
    else
        info "FFmpeg: real-time render complete"
    fi

    # Now stop the container
    $DOCKER stop -t 10 "$CONTAINER_NAME" > /dev/null 2>&1 || true
    $DOCKER rm -f "$CONTAINER_NAME" > /dev/null 2>&1 || true
    sleep 1

    local wall_display=$(echo "scale=1; $wall_ms / 1000" | bc 2>/dev/null || echo "?")
    ok "Rendered in ${wall_display}s wall-clock"
    RESULTS+=("$label|$filename|${wall_ms}")
    TEST_NUM=$((TEST_NUM + 1))
}

# ── Phase 1: Render ──────────────────────────────────────────────────────────
declare -a RESULTS=()
TEST_NUM=1

echo -e "  ${DIM}Phase 1: Rendering (4 sequential tests)${RST}"
echo ""

run_test "CEF + FFmpeg"        "ch1_cef_ffmpeg"   cef     ffmpeg
echo ""
run_test "CEF + Offline"       "ch2_cef_offline"  cef     offline
echo ""
run_test "Ultralight + FFmpeg"  "ch3_ul_ffmpeg"    ul      ffmpeg
echo ""
run_test "Ultralight + Offline" "ch4_ul_offline"   ul      offline

# Audio is already stereo via -filter:a pan=stereo|c0=c0|c1=c1 in the AMCP ADD command.

# ── Phase 2: Analyse ─────────────────────────────────────────────────────────
echo ""
echo -e "  ${DIM}Phase 2: Analysing output files${RST}"
echo ""

declare -a ANALYSIS=()

# Wait for all files to be fully written (bind mount sync can lag)
info "Waiting for output files to settle..."
sleep 5

for r in "${RESULTS[@]}"; do
    IFS='|' read -r label filename wall_ms <<< "$r"
    local_mp4="$OUTPUT_DIR/${filename}.mp4"
    wall_s=$(echo "scale=1; $wall_ms / 1000" | bc 2>/dev/null || echo "?")

    if [ ! -f "$local_mp4" ]; then
        ANALYSIS+=("$label|FAIL|-|-")
        continue
    fi

    # Retry ffprobe up to 5 times (bind mount may still be syncing)
    nb_frames=""
    for attempt in 1 2 3 4 5; do
        nb_frames=$(ffprobe_cmd -v error -show_entries stream=nb_frames -of csv=p=0 "$local_mp4" 2>/dev/null | head -1 || echo "")
        if [ -n "$nb_frames" ] && [ "$nb_frames" != "N/A" ]; then
            break
        fi
        sleep 2
    done

    if [ -z "$nb_frames" ] || [ "$nb_frames" = "N/A" ]; then
        ANALYSIS+=("$label|FAIL (no moov)|-|-")
        continue
    fi

    # FFmpeg consumer is real-time by definition (sync clock locked).
    # Offline consumer speed = content_duration / wall_clock.
    if [[ "$label" == *"FFmpeg"* ]]; then
        speed="1.0"
    else
        speed=$(python3 -c "print(f'{$nb_frames / 25.0 / ($wall_ms / 1000.0):.1f}')" 2>/dev/null || echo "?")
    fi
    ANALYSIS+=("$label|$nb_frames|${speed}x|${wall_s}s")
done

echo -e "  ${BLUE}Results${RST}"
echo ""
printf "  ${WHITE}%-24s  %8s  %8s  %8s${RST}\n" "Configuration" "Frames" "Speed" "Wall"
printf "  %-24s  %8s  %8s  %8s\n" "────────────────────────" "────────" "────────" "────────"

for r in "${ANALYSIS[@]}"; do
    IFS='|' read -r label frames speed wall <<< "$r"
    if [[ "$frames" == FAIL* ]]; then
        printf "  ${PINK}%-24s  %8s  %8s  %8s${RST}\n" "$label" "$frames" "-" "-"
    else
        printf "  ${GREEN}%-24s${RST}  %8s  %8s  %8s\n" "$label" "$frames" "$speed" "$wall"
    fi
done

echo ""
info "FFmpeg consumer = real-time (~500 frames in 20s)"
info "Offline consumer = faster-than-real-time"
info "Verify sync: ffmpeg -i file.mp4 -vf select=eq(n\\,0) -frames:v 1 frame.png"
echo ""
