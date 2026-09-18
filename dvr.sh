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

# MPEG-TS timestamps wrap every 2^33/90000 s and ffmpeg stalls on any seek that
# crosses a wrap, so the playlist must not span one. A live running for months
# (EverPop) always has a wrap inside its window: start just after the last one.
# Args: first latest segment-seconds pts-of-first. Echoes the first segment to use.
wrap_clamp() {
  awk -v f="$1" -v l="$2" -v d="$3" -v p="$4" \
    'BEGIN { w = 95443.7177 - p; if (w < (l - f) * d) f += int((w + 30) / d) + 1; print f }'
}

if [[ ${1:-} == selftest ]]; then
  [[ $(wrap_clamp 100 200 5 0) == 100 ]]                          # no wrap in window
  [[ $(wrap_clamp 100 200 5 95400) == 115 ]]                      # wrap right at the start
  [[ $(wrap_clamp 2076002 2084071 5.005 72013.732) == 2080690 ]]  # EverPop
  echo ok; exit 0
fi

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

# Probe the first segment's timestamp and drop everything before the last wrap.
probe="$2.probe"
printf '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:%d\n#EXTINF:%s,\n%s\n#EXT-X-ENDLIST\n' \
  "$(( ${dur%.*} + 1 ))" "$dur" "${tmpl/@SQ@/$first}" > "$probe"
pts=$(ffprobe -v error -f hls -allowed_extensions ALL \
        -protocol_whitelist file,http,https,tcp,tls,crypto \
        -show_entries format=start_time -of csv=p=0 "$probe" 2>/dev/null) || pts=""
rm -f "$probe"
if [[ $pts =~ ^[0-9.]+$ ]]; then first=$(wrap_clamp "$first" "$latest" "$dur" "$pts"); fi

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
