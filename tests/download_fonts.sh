#!/bin/bash
# Download fonts used by test media and templates.
# Fonts are placed in tests/fonts/ and copied to tests/templates/
# so Docker containers can serve them alongside HTML templates.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FONT_DIR="$SCRIPT_DIR/fonts"
TMPL_DIR="$SCRIPT_DIR/templates"
mkdir -p "$FONT_DIR"

BLUE='\033[38;5;33m'
RST='\033[0m'
GREEN='\033[38;5;82m'
OK="${GREEN}\xE2\x9C\x94${RST}"

echo ""
echo -e "  ${BLUE}Downloading fonts to tests/fonts/${RST}"
echo ""

# Inter (UI font)
if [ ! -f "$FONT_DIR/Inter-Medium.ttf" ]; then
    echo -n "  Inter... "
    curl -fsSL -o /tmp/Inter.zip \
        "https://github.com/rsms/inter/releases/download/v4.1/Inter-4.1.zip"
    unzip -qoj /tmp/Inter.zip "extras/ttf/Inter-Medium.ttf" -d "$FONT_DIR"
    unzip -qoj /tmp/Inter.zip "extras/ttf/Inter-Regular.ttf" -d "$FONT_DIR"
    rm -f /tmp/Inter.zip
    echo -e "$OK"
else
    echo -e "  Inter... already present $OK"
fi

# JetBrains Mono (monospaced frame counters)
if [ ! -f "$FONT_DIR/JetBrainsMono-Medium.ttf" ]; then
    echo -n "  JetBrains Mono... "
    curl -fsSL -o /tmp/JetBrainsMono.zip \
        "https://github.com/JetBrains/JetBrainsMono/releases/download/v2.304/JetBrainsMono-2.304.zip"
    unzip -qoj /tmp/JetBrainsMono.zip "fonts/ttf/JetBrainsMono-Medium.ttf" -d "$FONT_DIR"
    rm -f /tmp/JetBrainsMono.zip
    echo -e "$OK"
else
    echo -e "  JetBrains Mono... already present $OK"
fi

# Copy to templates/ for Docker container access
echo -n "  Copying to templates/... "
cp "$FONT_DIR"/*.ttf "$TMPL_DIR/" 2>/dev/null || true
echo -e "$OK"

echo ""
echo -e "  ${BLUE}Fonts ready:${RST}"
ls -1 "$FONT_DIR"/*.ttf 2>/dev/null | while read f; do echo "    $(basename "$f")"; done
echo ""
