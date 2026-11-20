#!/bin/zsh

# Measure how the YouTube video is shifted against our raw recording.
#
# Usage: ./yt-align.sh -e <episode> [-r] [-v]
#
# The YouTube video doesn't always start where raw<ep>.mp3 starts: when the raw audio is YouTube's
# own download they match, but a local recording can have minutes of pre-show the video doesn't
# have (episode 142: 171.2 s). Every YouTube time (description timestamps, captions) is
#   youtube time = raw time - offset
#
# The offset is measured by matching words in our transcript (transcript-<ep>.raw.json) with
# YouTube's automatic captions (downloaded with yt-dlp, free): the median time difference of
# words that occur only once in both. Without automatic captions (they appear a while after the
# stream) it falls back to the difference in duration, if that is large.
#
# Output: youtube-offset-<ep>.txt  seconds, raw minus YouTube (%.3f)
#         youtube-offset-<ep>.info  method<TAB>evidence

SCRIPTS_DIR="${0:A:h}"
cd "$SCRIPTS_DIR"

. ./messages.sh
. ./logging.sh
. ./vars.sh
. ./utils.sh
. ./yt-helpers.sh

set -euo pipefail

EPISODE_NUMBER=""
REWRITE=false

while getopts ":e:rv" opt; do
    case ${opt} in
        e ) EPISODE_NUMBER=$OPTARG ;;
        r ) REWRITE=true ;;
        v ) set -x ;;
        * ) echo "Usage: $0 -e <episode> [-r] [-v]" >&2; exit 1 ;;
    esac
done

if [ -z "$EPISODE_NUMBER" ]; then
    print_error "This script needs episode number in order to work"
    exit 1
fi

prepare_logging "yt-align"
prepare_dir "$EPISODE_NUMBER"

EP="$EPISODE_NUMBER"
OUTPUT="youtube-offset-$EP.txt"
INFO="youtube-offset-$EP.info"
STREAM_FILE="stream-$EP.json"
TRANSCRIPT="transcript-$EP.raw.json"
RAW="raw$EP.mp3"

if [ -s "$OUTPUT" ] && [ "$REWRITE" = false ]; then
    print_message "YouTube offset: $(< "$OUTPUT") s ($(cut -f1 "$INFO" 2>/dev/null || echo cached))"
    exit 0
fi

for f in "$STREAM_FILE" "$TRANSCRIPT"; do
    if [ ! -s "$f" ]; then
        print_error "$f not found in $EPISODE_DIR (run stream.sh and audio.sh first)"
        exit 1
    fi
done

write_offset() {
    printf "%.3f\n" "$1" > "$OUTPUT"
    print -r -- "$2"$'\t'"$3" > "$INFO"
    print_success "YouTube offset: $(< "$OUTPUT") s, $2: $3"
}

# 1. Word matching against YouTube's automatic captions
check_ytdlp
rm -f youtube-autosubs-$EP.*(N)
yt-dlp --skip-download --write-auto-subs --sub-langs "$YT_LANGUAGE,$YT_LANGUAGE-orig" --sub-format json3 \
    -o "youtube-autosubs-$EP.%(ext)s" "$(jq -r '.url' "$STREAM_FILE")" >> "$LOG" 2>&1 || true
SUBS=(youtube-autosubs-$EP.*.json3(N))

if (( ${#SUBS} )); then
    RESULT=$(jq -n --slurpfile y "${SUBS[1]}" --slurpfile t "$TRANSCRIPT" '
        def norm: ascii_downcase | gsub("[^\\p{L}]"; "");
        def unique_words: map(select(.w | length >= 7)) | group_by(.w) | map(select(length == 1) | .[0] | { key: .w, value: .t }) | from_entries;
        ([ $y[0].events[] | select(.segs) | .tStartMs as $s | .segs[]
           | { w: (.utf8 | norm), t: (($s + (.tOffsetMs // 0)) / 1000) } ] | unique_words) as $Y
        | ([ $t[0].segments[] | .words[]? | { w: (.text | norm), t: .start } ] | unique_words) as $T
        | [ $Y | keys[] | select($T[.] != null) | $T[.] - $Y[.] ] | sort as $d
        | if ($d | length) == 0 then { matches: 0 }
          else ($d[($d | length / 2 | floor)]) as $m
            | { matches: ($d | length), median: $m, close: ([ $d[] | select(. - $m | fabs < 2) ] | length) } end')
    MATCHES=$(jq '.matches' <<< "$RESULT")
    CLOSE=$(jq '.close // 0' <<< "$RESULT")
    if (( MATCHES >= YT_ALIGN_MIN_MATCHES && CLOSE * 10 >= MATCHES * 8 )); then
        write_offset "$(jq '.median' <<< "$RESULT")" captions "$CLOSE of $MATCHES matched words within 2 s"
        exit 0
    fi
    print_message "The automatic captions don't match well enough ($CLOSE of $MATCHES words), falling back to the durations"
else
    print_message "No automatic captions on YouTube yet, falling back to the durations"
fi

# 2. Difference in duration: only trusted when it is large (a few seconds of difference is just the tail)
RAW_DURATION=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$RAW")
YT_DURATION=$(jq -r '.duration // empty' "$STREAM_FILE")
if [ -z "$YT_DURATION" ]; then
    write_offset 0 default "no stream duration, assuming the video starts with the raw audio"
elif (( RAW_DURATION - YT_DURATION > 15 )); then
    write_offset "$(( RAW_DURATION - YT_DURATION ))" duration "raw is $(printf %.0f $(( RAW_DURATION - YT_DURATION ))) s longer than the video, assuming it is all at the start (approximate, run again with -r once YouTube has captions)"
else
    write_offset 0 duration "raw and video last the same ($(printf %.0f "$RAW_DURATION") s vs $YT_DURATION s)"
fi
