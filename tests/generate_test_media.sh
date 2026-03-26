#!/bin/bash
# Generate the sync_test.mp4 source video for the matrix benchmark.
#
# This video is designed to visually pair with tests/templates/sync_test.html:
# - Subtle dark blue blurred organic background
# - Big centered frame counter (full white, offset LEFT of center)
# - Overlay's frame counter is offset RIGHT of center
# - Together they show video vs overlay frame numbers side by side
# - Alternating color bar at top: green (even) / pink (odd)
# - Overlay's bar is cyan (even) / yellow (odd) — offset 8px down
# - White square blink (44x44, centered) every 25 frames (1/sec)
# - 1kHz sine bleep for 1 frame every second, synced with the square blink
# - Silence between bleeps (audio-video sync verification)
#
# Duration: 20s at 25fps = 500 frames
#
# Usage: ./generate_sync_test.sh [output_path]
# Default: tests/media/sync_test.mp4

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="${1:-$SCRIPT_DIR/media/sync_test.mp4}"

FFMPEG="${FFMPEG:-$(command -v ffmpeg 2>/dev/null || echo /opt/homebrew/bin/pkgx\ ffmpeg)}"

# Font paths — download if missing
FONT_DIR="$SCRIPT_DIR/fonts"
if [ ! -f "$FONT_DIR/JetBrainsMono-Medium.ttf" ]; then
    echo "Fonts not found. Running download_fonts.sh..."
    bash "$SCRIPT_DIR/download_fonts.sh"
fi
FONT_MONO="${FONT_MONO:-$FONT_DIR/JetBrainsMono-Medium.ttf}"
FONT_MONO_BOLD="${FONT_MONO_BOLD:-$FONT_DIR/JetBrainsMono-Medium.ttf}"

W=1280 H=720 FPS=25 DUR=20

echo "Generating sync_test.mp4 (${W}x${H} ${FPS}fps ${DUR}s)..."

# Audio: 1-frame 1kHz sine bleep every second (frame 0, 25, 50, ...),
# silence the rest. At 25fps, one frame = 1920 samples at 48kHz.
# Use aevalsrc with a modular expression to gate the tone.
$FFMPEG -y \
  -f lavfi -i "color=c=#1e1e2a:s=${W}x${H}:r=${FPS}:d=${DUR}" \
  -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=${DUR}" \
  -filter_complex "\
[0:v]format=yuv420p,\
geq=\
r='0':\
g='0':\
b='clip(30+25*sin(2*PI*N/400+X/300+Y/250)+15*sin(2*PI*N/280+X/200+Y/350+1.5)\,0\,70)',\
gblur=sigma=80,\
drawtext=fontfile=${FONT_MONO_BOLD}:text='%{frame_num}':start_number=0:fontsize=120:fontcolor=white:x=(w-text_w)/2-160:y=(h-text_h)/2,\
drawbox=x=0:y=0:w=iw:h=8:color=0x39ff14:t=fill:enable='eq(mod(n\,2)\,0)',\
drawbox=x=0:y=0:w=iw:h=8:color=0xff1493:t=fill:enable='eq(mod(n\,2)\,1)',\
drawbox=x=(iw-44)/2:y=(ih-44)/2:w=44:h=44:color=white:t=fill:enable='eq(mod(n\,${FPS})\,0)'\
[vout];\
[1:a]asplit[a1][a2];\
[a1]volume='if(lt(mod(t,1),1/${FPS})*eq(floor(mod(t,2)),0),1,0)':eval=frame[al];\
[a2]volume='if(lt(mod(t,1),1/${FPS})*eq(floor(mod(t,2)),1),1,0)':eval=frame[ar];\
[al][ar]join=inputs=2:channel_layout=stereo:map=0.0-FL|1.0-FR[aout]" \
  -map "[vout]" -map "[aout]" \
  -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p \
  -c:a pcm_s16le \
  -t "${DUR}" \
  "$OUTPUT"

echo "Done: $OUTPUT"
$FFMPEG -i "$OUTPUT" -hide_banner 2>&1 | grep -E "Duration|Video|Audio" | head -3
