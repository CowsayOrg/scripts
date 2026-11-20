#!/bin/zsh

# Find the YouTube stream of an episode and save its id, url, title and duration.
#
# Usage: ./stream.sh -e <episode> [-r] [-v]
#
# Output: $COWSAY_DIR/<ep>/stream-<ep>.json  {id, url, title, duration, episode, vertical_id?, streamed_at, date}
# An existing stream-<ep>.json is reused unless -r is given (for example after the title was
# edited on YouTube).

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

prepare_logging "stream"
prepare_dir "$EPISODE_NUMBER"

OUTPUT="stream-$EPISODE_NUMBER.json"

# add_stream_date: saves when the stream started (streamed_at, epoch) and its date in the show's
# time zone (date, YYYY-MM-DD), used as the post date. Not in the channel listing, so one yt-dlp call.
add_stream_date() {
    local ts
    ts=$(yt-dlp --skip-download --print "%(release_timestamp)s %(timestamp)s" "$(jq -r '.url' "$OUTPUT")" 2>> "$LOG" \
        | tr ' ' '\n' | grep -E '^[0-9]+$' | head -1 || true)
    if [ -z "$ts" ]; then
        print_error "Could not get the stream date, the post will be dated today"
        return 0
    fi
    jq --argjson ts "$ts" --arg d "$(TZ="$SHOW_TIMEZONE" date -r "$ts" +%Y-%m-%d)" '.streamed_at = $ts | .date = $d' "$OUTPUT" > "$OUTPUT.tmp"
    mv "$OUTPUT.tmp" "$OUTPUT"
}

if [ -s "$OUTPUT" ] && [ "$REWRITE" = false ]; then
    if [ -z "$(jq -r '.date // empty' "$OUTPUT")" ]; then
        add_stream_date    # saved before the date was
    fi
    print_message "YouTube stream: $(jq -r '.title' "$OUTPUT") ($(jq -r '.url' "$OUTPUT"), streamed $(jq -r '.date // "?"' "$OUTPUT"))"
    exit 0
fi

# The normal stream, plus the id of its vertical copy (title ending in 📱) when there is one
STREAM=$(streams_json "$REWRITE" | jq --argjson ep "$EPISODE_NUMBER" '
    ([ .[] | select(.vertical and .number == $ep) ] | first) as $v
    | [ .[] | select(.episode == $ep) ] | first // empty
    | { id, url, title, duration, episode } + (if $v then { vertical_id: $v.id } else {} end)')

if [ -z "$STREAM" ]; then
    print_error "No stream for episode $EPISODE_NUMBER in the latest $STREAM_SEARCH_DEPTH streams of $YOUTUBE_CHANNEL_STREAMS"
    print_error "Its title must contain \"Live $EPISODE_NUMBER\". Otherwise give the title and the source by hand: -n \"<title>\" and -l <file> or -y <url>"
    exit 1
fi

print -r -- "$STREAM" > "$OUTPUT"
add_stream_date
print_success "YouTube stream: $(jq -r '.title' "$OUTPUT") ($(jq -r '.url' "$OUTPUT"), streamed $(jq -r '.date // "?"' "$OUTPUT"))"
