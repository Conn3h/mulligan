#!/bin/sh
# Converts a screen recording into the README demo GIF.
#
#   Tools/demo-gif.sh path/to/recording.mov [width]
#
# Writes docs/media/demo.gif via a two-pass ffmpeg encode: the first pass builds a palette
# from the actual frames so text stays crisp, the second dithers against it. Width defaults
# to 960 px, which reads well in a README without pushing the file past a few megabytes.
# Trim the recording first (QuickTime: Edit > Trim) so the GIF starts on the key press.
set -eu

if [ $# -lt 1 ] || [ ! -f "$1" ]; then
    echo "usage: $0 recording.mov [width]" >&2
    exit 1
fi
if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "error: ffmpeg is required (brew install ffmpeg)" >&2
    exit 1
fi

input=$1
width=${2:-960}
out_dir=$(cd "$(dirname "$0")/.." && pwd)/docs/media
out=$out_dir/demo.gif
palette=$(mktemp -t mulligan-palette).png
trap 'rm -f "$palette"' EXIT

mkdir -p "$out_dir"
filters="fps=15,scale=$width:-1:flags=lanczos"
ffmpeg -v error -y -i "$input" -vf "$filters,palettegen=stats_mode=diff" "$palette"
ffmpeg -v error -y -i "$input" -i "$palette" \
    -lavfi "$filters [x]; [x][1:v] paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" \
    "$out"

size=$(du -h "$out" | cut -f1)
echo "wrote $out ($size)"
echo "README embed, under the tagline:"
echo '![Mulligan: hold a key, talk, release](docs/media/demo.gif)'
