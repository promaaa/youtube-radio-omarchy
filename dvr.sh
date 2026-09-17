#!/bin/bash
# Build a seekable HLS playlist for a YouTube live.
#
# ffmpeg refuses to seek inside a live playlist, and YouTube's playlist only
# lists the last hour anyway. But every segment is addressable by sequence
# number (/sq/N/), older ones stay downloadable for hours, and segments that do
# not exist yet are held by the server until they do. So we write a *finished*
# playlist from the oldest segment still served to several hours into the
# future: mpv sees one long seekable file whose end keeps arriving on time.
#
# usage:  dvr.sh <media-playlist-url> <output.m3u8>
# stdout: "<first-seq> <latest-seq> <segment-seconds>"  (latest = live edge at build time)
set -euo pipefail

pl=$(curl -sfL --max-time 15 "$1")
seg=$(grep -m1 '^https\?://' <<<"$pl")
dur=$(grep -m1 '^#EXTINF:' <<<"$pl" | cut -d: -f2 | cut -d, -f1)
first=$(sed -n 's|.*/sq/\([0-9]*\)/.*|\1|p' <<<"$seg")
latest=$(grep '^https\?://' <<<"$pl" | tail -1 | sed -n 's|.*/sq/\([0-9]*\)/.*|\1|p')
[[ -n $first && -n $latest && -n $dur ]] || exit 3
tmpl=${seg/\/sq\/$first\//\/sq\/@SQ@\/}
expire=$(sed -n 's|.*/expire/\([0-9]*\)/.*|\1|p' <<<"$seg")

avail() { curl -sf -o /dev/null --max-time 10 -r 0-0 "${tmpl/@SQ@/$1}"; }

# Oldest segment YouTube still serves: step back doubling, then bisect.
lo=$first step=360
while (( step < 20000 )) && avail $((lo - step)); do lo=$((lo - step)); step=$((step * 2)); done
hi=$lo lo=$((lo - step))
while (( hi - lo > 1 )); do mid=$(((lo + hi) / 2)); if avail "$mid"; then hi=$mid; else lo=$mid; fi; done
first=$hi

# Extend into the future until shortly before the signed URLs expire (max 6h).
now=$(date +%s)
horizon=$(( ${expire:-$((now + 21600))} - now - 600 ))
(( horizon > 21600 )) && horizon=21600
(( horizon < 600 )) && horizon=600
last=$(awk -v l="$latest" -v h="$horizon" -v d="$dur" 'BEGIN { printf "%d", l + h / d }')

{
  printf '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:%d\n#EXT-X-MEDIA-SEQUENCE:%d\n' "$(( ${dur%.*} + 1 ))" "$first"
  awk -v t="$tmpl" -v d="$dur" -v a="$first" -v b="$last" \
    'BEGIN { for (i = a; i <= b; i++) { u = t; sub(/@SQ@/, i, u); print "#EXTINF:" d ","; print u } }'
  printf '#EXT-X-ENDLIST\n'
} > "$2.tmp" && mv "$2.tmp" "$2"

echo "$first $latest $dur"
