#!/bin/sh
# make-icon.sh – renders the DashMirror app icon from Design/AppIcon/mobile-casting.svg (Nucleo, see its notice).
#
#   brew install librsvg     # once, provides rsvg-convert
#   scripts/make-icon.sh
#
# Light:  black symbol on white.  Dark and tinted (iOS): white symbol on black.
set -eu
cd "$(dirname "$0")/.."
SRC=Design/AppIcon/mobile-casting.svg
OUT=DashMirror/Assets.xcassets/AppIcon.appiconset
command -v rsvg-convert >/dev/null || { echo "rsvg-convert missing: brew install librsvg" >&2; exit 1; }

# Symbol content without the outer <svg> element and the comment.
INNER=$(sed -n '/<svg/,$p' "$SRC" | sed -e 's#<svg[^>]*>##' -e 's#</svg>##')
# 48-pt glyph at 58 % of the 1024 px icon: 594 px -> scale 12.375, offset 215 px.
render() { # $1 background, $2 symbol color, $3 output file
    printf '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024"><rect width="1024" height="1024" fill="%s"/><g transform="translate(215 215) scale(12.375)" color="%s">%s</g></svg>' \
        "$1" "$2" "$INNER" | rsvg-convert -w 1024 -h 1024 -o "$OUT/$3"
    echo "written: $OUT/$3"
}
render "#FFFFFF" "#000000" AppIcon.png
render "#000000" "#FFFFFF" AppIcon-Dark.png
render "#000000" "#FFFFFF" AppIcon-Tinted.png
