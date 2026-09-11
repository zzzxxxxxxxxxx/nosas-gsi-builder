#!/usr/bin/env bash
# usage: prepare-input.sh <url | directory> <output.img>
#
# Downloads (or collects) whatever the caller points at, unpacks common
# compression formats, and leaves a single image at <output.img>.
set -euo pipefail

src="$1"
out="$2"
work="$(dirname "$out")"
tmp="$work/dl"

rm -rf "$tmp"
mkdir -p "$tmp"

if [[ "$src" =~ ^https?:// ]]; then
  echo ">> downloading $src"
  curl -fL --retry 3 --retry-delay 2 -o "$tmp/download.bin" "$src"
else
  echo ">> using local directory $src"
  cp -a "$src"/. "$tmp"/ 2>/dev/null || true
fi

echo ">> collected:"
find "$tmp" -maxdepth 2 -type f -printf '   %10s  %p\n' | sort -rn | head -10

# unpack if we recognise an archive
while read -r f; do
  case "$f" in
    *.tar.gz|*.tgz)   echo ">> tar -xzf $f"; tar -xzf "$f" -C "$tmp" ;;
    *.tar.xz|*.txz)   echo ">> tar -xJf $f"; tar -xJf "$f" -C "$tmp" ;;
    *.img.xz|*.xz)    echo ">> xz -dk $f";   xz -dk "$f" ;;
    *.img.gz|*.gz)    echo ">> gzip -dk $f"; gzip -dk "$f" ;;
    *.zip)            echo ">> unzip $f";    unzip -o -q "$f" -d "$tmp" ;;
  esac
done < <(find "$tmp" -maxdepth 2 -type f \
           \( -name '*.tar.gz' -o -name '*.tgz' -o -name '*.tar.xz' -o -name '*.txz' \
              -o -name '*.xz' -o -name '*.gz' -o -name '*.zip' \) | sort)

# pick the biggest remaining regular file that is not an archive/checksum
img="$(find "$tmp" -type f \
        ! -name '*.xz' ! -name '*.gz' ! -name '*.zip' ! -name '*.tar*' \
        ! -name '*.txt' ! -name '*.md5' ! -name '*.sha*' \
        -printf '%s %p\n' | sort -rn | head -1 | cut -d' ' -f2-)"

[ -n "$img" ] || { echo "!! no usable image found under $tmp" >&2; exit 1; }

echo ">> selected: $img ($(stat -c%s "$img") bytes)"
mkdir -p "$(dirname "$out")"
mv -f "$img" "$out"
sync
ls -la "$out"

sz="$(stat -c%s "$out")"
if [ "$sz" -lt 500000000 ]; then
  echo "!! image looks too small ($sz bytes) -- is that really a system.img?" >&2
  exit 1
fi
echo ">> ok"
