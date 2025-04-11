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

. ./messages.sh
. ./logging.sh
. ./vars.sh

print_message "Preparing to execute the script"

set -euo pipefail
# set -x

# Prepare the logs
prepare_logging "topics_format"

# Check on OS

OS="$(uname -s)"

if [ $OS != "Darwin" ]; then
    print_message "This script is meant to be running on macOS"
    exit 1
fi

# Check for episode number to be present

if [ -z "$1" ]; then
    print_error "This script needs episode number in order to work"
    exit 1
fi

# Dirs

EPISODE_DIR=""$COWSAY_DIR"$1"

if [ ! -d "$EPISODE_DIR" ]; then
    mkdir -p "$EPISODE_DIR" > "$LOG" 2>&1
fi
cd "$EPISODE_DIR" > "$LOG" 2>&1

INPUT_FILE="Records-$1.csv"
INTERMEDIETE_FILE="temp.csv"
csvformat -D "¬" "$INPUT_FILE" > "$INTERMEDIETE_FILE" > "$LOG" 2>&1
YOUTUBE_TOPICS_FILE="topics-$1.txt"
EPISODE_TOPICS_FILE="topics-$1.md"
CUT="cut-$1.txt"

rm -f "$YOUTUBE_TOPICS_FILE" > "$LOG" 2>&1
rm -f "$CUT" > "$LOG" 2>&1
rm -f "$EPISODE_TOPICS_FILE" > "$LOG" 2>&1

print_message "Processing the file"

while IFS=¬ read -r col1 col2 col3
do
    TIME=${col1:0:-4}
    if [ "$col2" = "moment" ]; then
        continue
    elif [ "$col2" = "cut" ]; then
        echo "$TIME" >> "$CUT"
    elif [ "$col2" = "" ]; then
        continue
    elif [ "$col2" = "Intro" ] || [ "$col2" = "Outro" ]; then
        echo "$TIME - $col2"  >> $YOUTUBE_TOPICS_FILE
    elif [ "$col3" = "" ]; then
        echo "$TIME - $col2"  >> $YOUTUBE_TOPICS_FILE
        echo "* $col2"  >> $EPISODE_TOPICS_FILE
    else
        echo "$TIME - $col2: $col3"  >> $YOUTUBE_TOPICS_FILE
        echo "* [$col2]($col3)"  >> $EPISODE_TOPICS_FILE
    fi
done <  "$INTERMEDIETE_FILE"

rm -f "$INTERMEDIETE_FILE" > "$LOG" 2>&1

print_success "The show notes have been formater 🐮"