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

OUTPUT_DIR="tests/output-matrix"
# Remove only the specific output files we'll create (don't nuke the whole dir)
rm -f "$OUTPUT_DIR"/ch1_*.mp4 "$OUTPUT_DIR"/ch2_*.mp4 "$OUTPUT_DIR"/ch3_*.mp4 "$OUTPUT_DIR"/ch4_*.mp4
mkdir -p "$OUTPUT_DIR"

CONTAINER_NAME="casparcg-matrix"
CONFIG="$REPO_DIR/tests/config/offline.config"

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
        -v "$REPO_DIR/tests/media:/media:ro" \
        -v "$REPO_DIR/tests/templates:/templates" \
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

    # Render + flush: measure total wall-clock including I/O.
    # Uses a persistent AMCP connection for precise polling (no TCP overhead).
    # Detects video end via <time> reaching duration (same as test_precise_render).
    # Issues REMOVE on the same connection for zero-latency flush.
    local wall_ms
    local mp4_path="$OUTPUT_DIR/${filename}.mp4"
    local remove_cmd
    if [ "$cons" = "offline" ]; then
        remove_cmd="REMOVE 1 OFFLINE /output/${filename}.mp4"
    else
        remove_cmd="REMOVE 1 FILE /output/${filename}.mp4"
    fi

    wall_ms=$(python3 << PYEOF
import socket, time, re, os, sys

PORT = $PORT
src_duration = float($duration)
remove_cmd = "$remove_cmd"

def amcp_session():
    s = socket.socket()
    s.settimeout(30)
    s.connect(('localhost', PORT))
    return s

t0 = time.monotonic()

# Poll with persistent connection until video time reaches duration
poll = amcp_session()
done = False

while time.monotonic() - t0 < 120 and not done:
    try:
        poll.send(b'INFO 1-1\r\n')
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
                # Video ended — REMOVE on same connection (zero latency)
                poll.send((remove_cmd + '\r\n').encode())
                time.sleep(0.5)
                try: poll.recv(8192)
                except: pass
                done = True
                break
    except:
        try: poll.close()
        except: pass
        poll = amcp_session()

    time.sleep(0.01)  # 10ms poll interval

try: poll.close()
except: pass

if not done:
    # Timeout fallback — still try to flush
    try:
        s = amcp_session()
        s.send((remove_cmd + '\r\n').encode())
        time.sleep(1)
        s.recv(4096)
        s.close()
    except: pass

# Wait for file to stabilize (moov atom written)
prev_size = 0
for _ in range(15):
    time.sleep(0.5)
    try:
        cur_size = os.path.getsize("$mp4_path")
        if cur_size == prev_size and cur_size > 0:
            break
        prev_size = cur_size
    except:
        pass

# Total wall-clock: COMMIT to file flushed
print(int((time.monotonic() - t0) * 1000))
PYEOF
)
    info "Render + flush complete"

    # Stop the container
    $DOCKER stop -t 10 "$CONTAINER_NAME" > /dev/null 2>&1 || true
    $DOCKER rm -f "$CONTAINER_NAME" > /dev/null 2>&1 || true
    sleep 1

    local wall_s=$(python3 -c "print(f'{$wall_ms / 1000:.1f}')")
    ok "Rendered in ${wall_s}s wall-clock"
    RESULTS+=("$label|$filename|${wall_ms}|$target")
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
    IFS='|' read -r label filename wall_ms expected <<< "$r"
    local_mp4="$OUTPUT_DIR/${filename}.mp4"
    wall_s=$(python3 -c "print(f'{$wall_ms / 1000:.1f}')")

    if [ ! -f "$local_mp4" ]; then
        ANALYSIS+=("$label|FAIL|-|-|-")
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
        ANALYSIS+=("$label|FAIL (no moov)|-|-|-")
        continue
    fi

    # Speed = content_duration / wall_clock (for all consumers)
    speed=$(python3 -c "print(f'{$nb_frames / 25.0 / ($wall_ms / 1000.0):.1f}')" 2>/dev/null || echo "?")

    # Frame accuracy: difference from expected
    diff=$((nb_frames - expected))
    if [ "$diff" -eq 0 ]; then
        accuracy="exact"
    elif [ "$diff" -gt 0 ]; then
        accuracy="+${diff}"
    else
        accuracy="${diff}"
    fi

    ANALYSIS+=("$label|$nb_frames|${speed}x|${wall_s}s|${accuracy}")
done

echo -e "  ${BLUE}Results${RST}"
echo ""
printf "  ${WHITE}%-24s  %8s  %8s  %8s  %8s${RST}\n" "Configuration" "Frames" "Speed" "Wall" "Accuracy"
printf "  %-24s  %8s  %8s  %8s  %8s\n" "────────────────────────" "────────" "────────" "────────" "────────"

for r in "${ANALYSIS[@]}"; do
    IFS='|' read -r label frames speed wall accuracy <<< "$r"
    if [[ "$frames" == FAIL* ]]; then
        printf "  ${PINK}%-24s  %8s  %8s  %8s  %8s${RST}\n" "$label" "$frames" "-" "-" "-"
    elif [[ "$accuracy" == "exact" ]]; then
        printf "  ${GREEN}%-24s${RST}  %8s  %8s  %8s  ${GREEN}%8s${RST}\n" "$label" "$frames" "$speed" "$wall" "$accuracy"
    else
        printf "  ${PINK}%-24s${RST}  %8s  %8s  %8s  ${PINK}%8s${RST}\n" "$label" "$frames" "$speed" "$wall" "$accuracy"
    fi
done

echo ""
info "Source: 500 frames, 25fps, 20s"
info "Speed = content duration / wall-clock (including flush)"
info "Verify sync: ffmpeg -i file.mp4 -vf select=eq(n\\,0) -frames:v 1 frame.png"
echo ""
