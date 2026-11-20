#!/bin/zsh

# Print the episodes streamed on YouTube but not published on cowsay.show, oldest first, one per line.
#
# Usage: ./unpublished.sh [-v]
#
# Published: the episode numbers in the site feed ($SITE_FEED_URL), from the item links
# (https://cowsay.show/2026/09/08/173.html -> 173). The feed only has the latest episodes, so it is
# a window: only streams newer than its oldest episode are considered.
# Streamed: normal (not 📱) streams whose title has the number after "live" (see yt-helpers.sh).

SCRIPTS_DIR="${0:A:h}"
cd "$SCRIPTS_DIR"

. ./messages.sh
. ./vars.sh
. ./yt-helpers.sh

set -euo pipefail

[ "${1:-}" = "-v" ] && set -x

if ! FEED=$(curl -sf "$SITE_FEED_URL"); then
    print_error "Could not read the site feed $SITE_FEED_URL" >&2
    exit 1
fi

PUBLISHED=$(print -r -- "$FEED" | grep -oE '<link>[^<]*/[0-9]+\.html' | grep -oE '[0-9]+\.html' | grep -oE '[0-9]+' | sort -un)
if [ -z "$PUBLISHED" ]; then
    print_error "No episodes found in $SITE_FEED_URL" >&2
    exit 1
fi
OLDEST=$(print -r -- "$PUBLISHED" | head -1)

STREAMS=$(streams_json)

jq -r --argjson oldest "$OLDEST" --argjson published "[$(print -r -- "$PUBLISHED" | paste -sd, -)]" '
    [ .[] | .episode | select(. != null and . > $oldest) ] | unique
    | map(select(. as $e | $published | index($e) | not)) | .[]
' <<< "$STREAMS"
