#!/usr/bin/env bash
# usage: prepare-input.sh <url | directory> <output.img>
#
# Grabs whatever the caller points at, unpacks it (recognised by *magic*, not
# by file name -- URLs often carry no useful extension), and leaves a single
# Android image at <output.img>. Understands gzip / xz / zip / tar.[gz|xz],
# plus sparse and raw ext4 images.
set -euo pipefail

src="$1"
out="$2"
work="$(dirname "$out")"
tmp="$work/dl"

rm -rf "$tmp"
mkdir -p "$tmp"

# ---------------------------------------------------------------- download
if [[ "$src" =~ ^https?:// ]]; then
  # keep the URL's file name when there is one (nicer logs), else download.bin
  name="$(basename "${src%%\?*}")"
  name="${name:-download.bin}"
  echo ">> downloading $src"
  curl -fL --retry 3 --retry-delay 2 -o "$tmp/$name" "$src"
else
  echo ">> using local directory $src"
  cp -a "$src"/. "$tmp"/ 2>/dev/null || true
fi

echo ">> collected:"
find "$tmp" -maxdepth 2 -type f -printf '   %12s  %p\n' | sort -rn | head -10

# ----------------------------------------------------------------- sniffing
sniff() { # -> gzip | xz | zip | sparse | ext4 | unknown
  local f="$1" m
  m="$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')"
  case "$m" in
    1f8b*)       echo gzip ;;
    fd377a58)    echo xz ;;
    504b0304)    echo zip ;;
    3aff26ed)    echo sparse ;;
    *)
      # ext4 superblock magic 0xef53 lives at offset 1024 + 56
      if [ "$(od -An -tx1 -j 1080 -N2 "$f" 2>/dev/null | tr -d ' \n')" = "53ef" ]; then
        echo ext4
      else
        echo unknown
      fi
      ;;
  esac
}

# ---------------------------------------------------------------- unpack
# Iterate a few times so nested containers (e.g. tar.gz holding a zip) work.
for _ in 1 2 3; do
  did=0
  while IFS= read -r f; do
    dest="${f%.gz}"; [ "$dest" = "$f" ] && dest="$f.unpacked"
    case "$(sniff "$f")" in
      gzip)
        echo ">> gzip -dc $f > $dest"
        gzip -dc "$f" > "$dest" && rm -f "$f"
        did=1 ;;
      xz)
        dest="${f%.xz}"; [ "$dest" = "$f" ] && dest="$f.unpacked"
        echo ">> xz -dc   $f > $dest"
        xz -dc "$f" > "$dest" && rm -f "$f"
        did=1 ;;
      zip)
        echo ">> unzip    $f"
        unzip -o -q "$f" -d "$tmp" && rm -f "$f"
        did=1 ;;
    esac
  # no size filter here: a 2.5G image can gzip down below 1M when it is mostly
  # zeros, and we want to look at every candidate anyway
  done < <(find "$tmp" -type f | sort)
  [ "$did" = 1 ] || break
done

# tar archives keep their extension visible now that the outer gzip/xz is gone
while IFS= read -r f; do
  case "$f" in
    *.tar)          echo ">> tar -xf   $f"; tar -xf  "$f" -C "$tmp" && rm -f "$f" ;;
    *.tar.gz|*.tgz) echo ">> tar -xzf  $f"; tar -xzf "$f" -C "$tmp" && rm -f "$f" ;;
    *.tar.xz|*.txz) echo ">> tar -xJf  $f"; tar -xJf "$f" -C "$tmp" && rm -f "$f" ;;
  esac
done < <(find "$tmp" -type f | sort)

echo ">> after unpack:"
while IFS= read -r f; do
  printf '   %-8s %12s  %s\n' "$(sniff "$f")" "$(stat -c%s "$f")" "$f"
done < <(find "$tmp" -maxdepth 2 -type f | sort)

# ---------------------------------------------------------------- pick
img=""
while IFS= read -r f; do
  case "$(sniff "$f")" in
    sparse|ext4)
      if [ -z "$img" ] || [ "$(stat -c%s "$f")" -gt "$(stat -c%s "$img")" ]; then
        img="$f"
      fi ;;
  esac
done < <(find "$tmp" -type f | sort)

if [ -z "$img" ]; then
  echo "!! no sparse/ext4 image found under $tmp" >&2
  echo "!! (the list above is what we actually got -- check the URL points at the image itself)" >&2
  exit 1
fi

kind="$(sniff "$img")"
sz="$(stat -c%s "$img")"
echo ">> selected: $img  kind=$kind  size=$sz"

if [ "$sz" -lt 200000000 ]; then
  echo "!! image is suspiciously small ($sz bytes)" >&2
  exit 1
fi

mkdir -p "$(dirname "$out")"
mv -f "$img" "$out"
sync
ls -la "$out"
echo ">> ok ($kind)"
