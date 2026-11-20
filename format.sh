#!/bin/zsh

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title cow format-topics
# @raycast.mode fullOutput

# Optional parameters:
# @raycast.icon 🎼
# @raycast.argument1 { "type": "text", "placeholder": "Episode Number" }
# @raycast.packageName cowsay-audio
# @raycast.needsConfirmation true

# Documentation:
# @raycast.description download audio from youtube
# @raycast.author vladd
# @raycast.authorURL https://raycast.com/vladd

# Turn Records-<ep>.csv (podcast timeline) into:
#   topics-<ep>.txt    YouTube description list, on the uncut video timeline (+ cut offset)
#   topics-<ep>.md     website topic list
#   chapters-<ep>.yml  Octopod chapter marks for the post front matter
#
# Usage: ./format.sh <episode> [-v]

. ./messages.sh
. ./logging.sh
. ./vars.sh
. ./utils.sh

print_message "Preparing to execute the script"

set -euo pipefail

if [ "${2:-}" = "-v" ]; then
    set -x
fi

# Prepare the logs
prepare_logging "topics_format"

# Check on OS

OS="$(uname -s)"

if [ $OS != "Darwin" ]; then
    print_message "This script is meant to be running on macOS"
    exit 1
fi

# Check for episode number to be present

if [ -z "${1:-}" ]; then
    print_error "This script needs episode number in order to work"
    exit 1
fi

# Dirs

prepare_dir "$1"

INPUT_FILE="Records-$1.csv"
INTERMEDIETE_FILE="temp.csv"
YOUTUBE_TOPICS_FILE="topics-$1.txt"
EPISODE_TOPICS_FILE="topics-$1.md"
CHAPTERS_FILE="chapters-$1.yml"
CUT_FILE="cut-$1.txt"

if [ ! -f "$INPUT_FILE" ]; then
    print_error "$INPUT_FILE not found in $EPISODE_DIR"
    exit 1
fi

csvformat -D "¬" "$INPUT_FILE" > "$INTERMEDIETE_FILE" 2>> "$LOG"

rm -f "$YOUTUBE_TOPICS_FILE" "$EPISODE_TOPICS_FILE" "$CHAPTERS_FILE"
touch "$YOUTUBE_TOPICS_FILE" "$EPISODE_TOPICS_FILE" "$CHAPTERS_FILE"

# YouTube time = podcast time + cut - YouTube offset (yt-align.sh: how much of the raw audio's start
# the video doesn't have). Without an offset file the video is assumed to start with the raw audio.
CUT=0
LEGACY_CUT=false
if [ -f "$CUT_FILE" ]; then
    CUT_VALUE=$(< "$CUT_FILE")
    if [[ "$CUT_VALUE" == *:* ]]; then    # old manual cut files (HH:MM:SS)
        IFS=: read -r h m sec <<< "$CUT_VALUE"
        CUT=$(( 10#$h * 3600 + 10#$m * 60 + 10#${sec%.*} ))
        LEGACY_CUT=true
    else
        CUT=$CUT_VALUE
    fi
fi
YT_OFFSET_FILE="youtube-offset-$1.txt"
if [ -f "$YT_OFFSET_FILE" ]; then
    YT_OFFSET=$(< "$YT_OFFSET_FILE")
elif [ "$LEGACY_CUT" = true ]; then
    YT_OFFSET=$CUT    # the old flow never shifted the YouTube times
else
    YT_OFFSET=0
fi
typeset -i OFFSET=$(printf "%.0f" $(( CUT - YT_OFFSET )))    # typeset -i turns "-0" into 0

# to_seconds HH:MM:SS -> seconds
to_seconds() {
    local h m s
    IFS=: read -r h m s <<< "$1"
    print -r -- $(( 10#$h * 3600 + 10#$m * 60 + 10#$s ))
}

# to_hms seconds -> HH:MM:SS
to_hms() {
    printf "%02d:%02d:%02d" $(( $1 / 3600 )) $(( $1 % 3600 / 60 )) $(( $1 % 60 ))
}

SQ="'"

print_message "Processing the file"

while IFS=¬ read -r col1 col2 col3
do
    TIME=${col1:0:-4}
    if [ "$col2" = "moment" ] || [ "$col2" = "cut" ] || [ "$col2" = "" ]; then
        continue
    fi

    VIDEO_SECONDS=$(( $(to_seconds "$TIME") + OFFSET ))
    if [ "$col2" = "Intro" ] || (( VIDEO_SECONDS < 0 )); then
        VIDEO_SECONDS=0    # YouTube chapters need the first timestamp at 00:00:00
    fi
    VIDEO_TIME=$(to_hms $VIDEO_SECONDS)
    echo "  - '$col1 ${col2//$SQ/$SQ$SQ}'" >> "$CHAPTERS_FILE"

    if [ "$col2" = "Intro" ] || [ "$col2" = "Outro" ]; then
        echo "$VIDEO_TIME - $col2"  >> "$YOUTUBE_TOPICS_FILE"
    elif [ "$col3" = "" ]; then
        echo "$VIDEO_TIME - $col2"  >> "$YOUTUBE_TOPICS_FILE"
        echo "* $col2"  >> "$EPISODE_TOPICS_FILE"
    else
        echo "$VIDEO_TIME - $col2: $col3"  >> "$YOUTUBE_TOPICS_FILE"
        echo "* [$col2]($col3)"  >> "$EPISODE_TOPICS_FILE"
    fi
done <  "$INTERMEDIETE_FILE"

rm -f "$INTERMEDIETE_FILE"

# Chapters must be in time order (lines start with the zero-padded time)
sort -o "$CHAPTERS_FILE" "$CHAPTERS_FILE"

if [ "$OFFSET" != "0" ]; then
    print_message "YouTube timestamps shifted by $OFFSET s (cut $CUT s, the video starts $YT_OFFSET s into the raw audio)"
fi

print_success "The show notes and chapters have been formatted 🐮"
