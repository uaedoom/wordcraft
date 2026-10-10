#!/bin/bash
# Renders the marketing HTML pages to ../images/*.png with headless Chrome (2x).
cd "$(dirname "$0")"
C="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
r(){ "$C" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=2 --window-size=$2,$3 --screenshot="$PWD/../images/$1.png" "file://$PWD/$1.html" 2>/dev/null; }
r banner 1600 720; r story 1600 1270; r table 1600 920
