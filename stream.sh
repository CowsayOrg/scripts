#!/bin/zsh

# Find the YouTube stream of an episode and save its id, url, title and duration.
#
# Usage: ./stream.sh -e <episode> [-r] [-v]
#
# Output: $COWSAY_DIR/<ep>/stream-<ep>.json  {id, url, title, duration, episode}
# An existing stream-<ep>.json is reused unless -r is given (for example after the title was
# edited on YouTube).

SCRIPTS_DIR="${0:A:h}"
cd "$SCRIPTS_DIR"

. ./messages.sh
. ./logging.sh
. ./vars.sh
. ./utils.sh
. ./youtube.sh

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

if [ -s "$OUTPUT" ] && [ "$REWRITE" = false ]; then
    print_message "YouTube stream: $(jq -r '.title' "$OUTPUT") ($(jq -r '.url' "$OUTPUT"))"
    exit 0
fi

STREAM=$(streams_json "$REWRITE" | jq --argjson ep "$EPISODE_NUMBER" '[ .[] | select(.episode == $ep) ] | first // empty')

if [ -z "$STREAM" ]; then
    print_error "No stream for episode $EPISODE_NUMBER in the latest $STREAM_SEARCH_DEPTH streams of $YOUTUBE_CHANNEL_STREAMS"
    print_error "Its title must contain \"Live $EPISODE_NUMBER\". Otherwise give the title and the source by hand: -n \"<title>\" and -l <file> or -y <url>"
    exit 1
fi

print -r -- "$STREAM" > "$OUTPUT"
print_success "YouTube stream: $(jq -r '.title' "$OUTPUT") ($(jq -r '.url' "$OUTPUT"))"
