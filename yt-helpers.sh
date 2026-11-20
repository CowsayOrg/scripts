#!/bin/zsh

# YouTube stream helpers (sourced by stream.sh, unpublished.sh, yt-align.sh, youtube-update.sh and youtube-backfill.sh).
#
# Every episode is streamed on the channel, twice: the normal stream and a vertical one whose
# title ends in "📱". The normal stream title is the episode title ("Live 173: Season Finale!",
# "LIVE DE URGENȚĂ 174: ...") and carries the episode number after the word "live".

STREAMS_CACHE="$COWSAY_DIR/.streams.json"
STREAMS_CACHE_MINUTES=10

# jq: episode number of a stream entry (null for titles without one), whether it is the vertical copy,
# and "episode": the number for normal streams only (null for the vertical ones)
JQ_EPISODE='
    def number: (.title | capture("(?i)live[^0-9]*(?<n>[0-9]+)")? | .n | tonumber) // null;
    def vertical: .title | test("📱\\s*$");
    def episode: if vertical then null else number end;
'

check_ytdlp() {
    if ! command -v yt-dlp > /dev/null 2>&1; then
        print_error "You miss yt-dlp. Please install all the dependencies from requirements.txt" >&2
        exit 1
    fi
}

# streams_json [force]: prints [{id, url, title, duration, episode}] for the latest
# $STREAM_SEARCH_DEPTH streams, newest first. Cached for a few minutes, so one run lists the channel once.
streams_json() {
    local force="${1:-false}" tmp
    if [ "$force" != true ] && [ -s "$STREAMS_CACHE" ] \
        && [ -n "$(find "$STREAMS_CACHE" -mmin -$STREAMS_CACHE_MINUTES 2>/dev/null)" ]; then
        cat "$STREAMS_CACHE"
        return 0
    fi

    check_ytdlp
    tmp="$STREAMS_CACHE.part"
    if ! yt-dlp --flat-playlist --playlist-end "$STREAM_SEARCH_DEPTH" -J "$YOUTUBE_CHANNEL_STREAMS" 2>> "${LOG:-/dev/null}" \
        | jq "$JQ_EPISODE"'[ .entries[] | { id, url: ("https://www.youtube.com/watch?v=" + .id), title, duration } | .episode = episode | .number = number | .vertical = vertical ]' \
        > "$tmp" || [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        print_error "Could not list the streams of $YOUTUBE_CHANNEL_STREAMS" >&2
        return 1
    fi
    mv "$tmp" "$STREAMS_CACHE"
    cat "$STREAMS_CACHE"
}
