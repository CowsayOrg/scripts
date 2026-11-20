#!/bin/zsh

# Find the recording of an episode on disk. Prints its path, or nothing if there is none
# (then the audio is downloaded from the YouTube stream). Messages go to stderr.
#
# Usage: ./find-audio.sh -e <episode> [-v]
#
# Search order:
#   1. $COWSAY_DIR/<ep>/raw<ep>.mp3 (an earlier run)
#   2. any other audio/video file in $COWSAY_DIR/<ep>/
#   3. $AUDIO_SEARCH_DIRS (~/Downloads): files named after the stream title, or containing
#      "live <ep>" (YouTube Studio names downloads after the title, with ":" and "?" as "_")
# Candidates from 2 and 3 must last as long as the stream (stream-<ep>.json, written by
# stream.sh) within $AUDIO_DURATION_TOLERANCE seconds. Audio is preferred over video, then newest.

SCRIPTS_DIR="${0:A:h}"
cd "$SCRIPTS_DIR"

. ./messages.sh
. ./vars.sh

set -euo pipefail

EPISODE_NUMBER=""

while getopts ":e:v" opt; do
    case ${opt} in
        e ) EPISODE_NUMBER=$OPTARG ;;
        v ) set -x ;;
        * ) echo "Usage: $0 -e <episode> [-v]" >&2; exit 1 ;;
    esac
done

if [ -z "$EPISODE_NUMBER" ]; then
    print_error "This script needs episode number in order to work" >&2
    exit 1
fi

EP="$EPISODE_NUMBER"
EPISODE_DIR="$COWSAY_DIR/$EP"
STREAM_FILE="$EPISODE_DIR/stream-$EP.json"
AUDIO_EXT=(mp3 m4a wav aac flac ogg opus)
VIDEO_EXT=(mp4 mov mkv webm)

TITLE=""
EXPECTED=""
if [ -s "$STREAM_FILE" ]; then
    TITLE=$(jq -r '.title // ""' "$STREAM_FILE")
    EXPECTED=$(jq -r '.duration // empty' "$STREAM_FILE")
fi

# 1. An earlier run already has the raw copy
if [ -f "$EPISODE_DIR/raw$EP.mp3" ]; then
    print_message "Using $EPISODE_DIR/raw$EP.mp3 from an earlier run" >&2
    print -r -- "$EPISODE_DIR/raw$EP.mp3"
    exit 0
fi

norm() { local s="${(L)1}"; print -r -- "${s//[^[:alnum:]]/}"; }

# matches <file>: the file name looks like this episode
matches() {
    local name="${${1:t}:r}"
    [ -n "$TITLE" ] && [ "$(norm "$name")" = "$(norm "$TITLE")" ] && return 0
    [[ "${(L)name}" =~ "live[^0-9]*$EP([^0-9]|\$)" ]]
}

# duration_ok <file>: its duration is close to the stream's (always true without a stream duration)
duration_ok() {
    local d
    [ -z "$EXPECTED" ] && return 0
    d=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null || true)
    if [ -z "$d" ]; then
        print_message "Skipping ${1:t}: can't read its duration" >&2
        return 1
    fi
    if (( d - EXPECTED > AUDIO_DURATION_TOLERANCE || EXPECTED - d > AUDIO_DURATION_TOLERANCE )); then
        print_message "Skipping ${1:t}: it lasts $(printf %.0f "$d") s, the stream $EXPECTED s" >&2
        return 1
    fi
}

# media <dir> <ext...>: files with these extensions, newest first
media() {
    local dir="$1" e files=()
    shift
    for e in "$@"; do files+=("$dir"/*.(#i)$e(N.)); done
    (( ${#files} )) && ls -t -- "${files[@]}"
    return 0
}

generated() {
    case "${1:t}" in
        raw*|cow$EP*|cropped*|compressed*|transcribe-upload-*) return 0 ;;
    esac
    return 1
}

setopt extended_glob

# 2. A file dropped into the episode directory
if [ -d "$EPISODE_DIR" ]; then
    for f in ${(f)"$(media "$EPISODE_DIR" "${AUDIO_EXT[@]}")"} ${(f)"$(media "$EPISODE_DIR" "${VIDEO_EXT[@]}")"}; do
        generated "$f" && continue
        if duration_ok "$f"; then
            print_message "Using $f" >&2
            print -r -- "$f"
            exit 0
        fi
    done
fi

# 3. Downloads (and any other $AUDIO_SEARCH_DIRS)
for dir in "${AUDIO_SEARCH_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    for f in ${(f)"$(media "$dir" "${AUDIO_EXT[@]}")"} ${(f)"$(media "$dir" "${VIDEO_EXT[@]}")"}; do
        matches "$f" || continue
        if duration_ok "$f"; then
            print_message "Using $f${EXPECTED:+ (duration matches the stream)}" >&2
            print -r -- "$f"
            exit 0
        fi
    done
done

print_message "No recording of episode $EP found on disk" >&2
