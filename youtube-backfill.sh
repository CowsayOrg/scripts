#!/bin/zsh

# Add the episodes missing from the "Lives" playlist, oldest first.
#
# Usage: ./youtube-backfill.sh [-n] [-v]
#   -n  dry run: only list them (works without the YouTube login)
#
# Missing: normal (not 📱) episode streams newer than the newest episode already in the playlist.
# Older episodes that aren't in it are left alone, on the assumption that was deliberate.
# The playlist is read with yt-dlp (free); each insert costs 50 of the 10,000 daily quota units.

SCRIPTS_DIR="${0:A:h}"
cd "$SCRIPTS_DIR"

. ./messages.sh
. ./logging.sh
. ./vars.sh
. ./yt-helpers.sh
. ./yt-api.sh

set -euo pipefail

DRY_RUN=false
while getopts ":nv" opt; do
    case ${opt} in
        n ) DRY_RUN=true ;;
        v ) set -x ;;
        * ) echo "Usage: $0 [-n] [-v]" >&2; exit 1 ;;
    esac
done

if [ "$DRY_RUN" = false ] && ! yt_configured; then
    print_error "YouTube is not set up yet. Run ./youtube-auth.sh once (or -n for a dry run)"
    exit 1
fi

prepare_logging "youtube-backfill"
check_ytdlp

IN_PLAYLIST=$(yt-dlp --flat-playlist --print id "https://www.youtube.com/playlist?list=$YT_LIVES_PLAYLIST" 2>> "$LOG" | jq -R . | jq -s .)
MISSING=$(streams_json | jq -c --argjson in "$IN_PLAYLIST" '
    ([ .[] | select(.episode != null and (.id as $i | $in | index($i))) | .episode ] | max // 0) as $newest
    | [ .[] | select(.episode != null and .episode > $newest and (.id as $i | $in | index($i) | not)) ]
    | sort_by(.episode) | .[]')

if [ -z "$MISSING" ]; then
    print_success "The Lives playlist is complete 🐮"
    exit 0
fi

print_message "Missing from the Lives playlist:"
jq -r '"  \(.episode)  \(.title)  https://youtu.be/\(.id)"' <<< "$MISSING"
COUNT=$(wc -l <<< "$MISSING" | tr -d ' ')

if [ "$DRY_RUN" = true ]; then
    print_message "Dry run, nothing changed ($COUNT videos, $(( COUNT * 50 )) quota units)"
    exit 0
fi

if headless; then
    gate backfill "add these $COUNT videos to the Lives playlist"
    ANSWER=y
else
    print_message "Add these $COUNT videos? y/[n]"
    read ANSWER
fi
if [ "$ANSWER" != "y" ]; then
    print_error "Nothing changed"
    exit 0
fi

for id in $(jq -r '.id' <<< "$MISSING"); do
    yt_add_to_playlist "$YT_LIVES_PLAYLIST" "$id"
    print_success "Added https://youtu.be/$id"
done
