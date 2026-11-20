#!/bin/zsh

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title cow template-md
# @raycast.mode fullOutput

# Optional parameters:
# @raycast.icon 🎼
# @raycast.argument1 { "type": "text", "placeholder": "Episode Number" }
# @raycast.argument2 { "type": "text", "placeholder": "Episode Title" }
# @raycast.packageName cowsay-audio
# @raycast.needsConfirmation true

# Documentation:
# @raycast.description download audio from youtube
# @raycast.author vladd
# @raycast.authorURL https://raycast.com/vladd

#1 episode number 
#2 episode duration
#3 episode title
#4 audio file size

. ./messages.sh
. ./logging.sh
. ./vars.sh
. ./r2.sh

# Prepare the logs
prepare_logging "markdown"

set -euo pipefail
# set -x

print_message "Preparing to execute the script"

# Check for episode number to be present
if [ -z "${1:-}" ]; then
    print_error "This script needs episode number in order to work"
    exit 1
fi

# Title: the argument, otherwise the YouTube stream title saved by stream.sh
EPISODE_TITLE="${2:-}"
STREAM_FILE="$COWSAY_DIR/$1/stream-$1.json"
if [ -z "$EPISODE_TITLE" ] && [ -s "$STREAM_FILE" ]; then
    EPISODE_TITLE=$(jq -r '.title' "$STREAM_FILE")
fi
VIDEO_LINE=""
if [ -s "$STREAM_FILE" ]; then
    VIDEO_LINE="
Urmăriți episodul pe [YouTube]($(jq -r '.url' "$STREAM_FILE"))
"
fi
if [ -z "$EPISODE_TITLE" ]; then
    print_error "This script needs episode title in order to work (or run ./stream.sh -e $1 first)"
    exit 1
fi

# Check on OS

OS="$(uname -s)"

if [ $OS != "Darwin" ]; then
    print_error "This script is meant to be running on macOS"
    exit 1
fi

# Dirs

EPISODE_DIR=""$COWSAY_DIR"/$1"

if [ ! -d "$EPISODE_DIR" ]; then
    mkdir -p "$EPISODE_DIR" > "$LOG" 2>&1
fi
cd "$EPISODE_DIR" > "$LOG" 2>&1

day_suffix() {
  case $1 in
    1|21|31) echo "st";;
    2|22)    echo "nd";;
    3|23)    echo "rd";;
    *)       echo "th";;
  esac
}

SQ="'"
TITLE="${EPISODE_TITLE//$SQ/$SQ$SQ}"    # single quotes are doubled inside a YAML '...' string
AUDIO_FILE_NAME="cow"$1".mp3"            # local file
AUDIO_OBJECT_NAME=$(r2_audio_name "$1")    # name in R2: cow<ep>.mp3 or cow<ep>-rev<n>.mp3 after a fix
DURATION=$(post_duration "$AUDIO_FILE_NAME")
AUDIO_SIZE=$(stat -f%z "$AUDIO_FILE_NAME")

# Regenerating an already existing post keeps its file name and date
# Date: the day the episode was streamed (stream.sh), so an old episode isn't dated today.
# A post that is already committed keeps its date: the date is in its URL and its feed id, and
# changing it would make podcast apps see a new episode. An uncommitted post is moved to the right date.
STREAM_DATE=""
if [ -s "$STREAM_FILE" ]; then
    STREAM_DATE=$(jq -r '.date // empty' "$STREAM_FILE")
fi
EXISTING_POST=$(find_post "$1")
if [ -n "$EXISTING_POST" ]; then
    DATE="${${EXISTING_POST:t}[1,10]}"
    if [ -n "$STREAM_DATE" ] && [ "$STREAM_DATE" != "$DATE" ]; then
        if git -C "${EXISTING_POST:h}" ls-files --error-unmatch "${EXISTING_POST:t}" > /dev/null 2>&1; then
            print_error "Post ${EXISTING_POST:t} is dated $DATE but the episode was streamed on $STREAM_DATE. It's already committed, so it keeps its date (rename it by hand if it was never published)"
        else
            print_message "Post ${EXISTING_POST:t} is dated $DATE, moving it to the stream date $STREAM_DATE"
            rm -f "$EXISTING_POST" "$EPISODE_DIR/${EXISTING_POST:t}"
            DATE="$STREAM_DATE"
        fi
    else
        print_message "Post ${EXISTING_POST:t} already exists, regenerating it with its original date"
    fi
elif [ -n "$STREAM_DATE" ]; then
    DATE="$STREAM_DATE"
else
    DATE=$(date +"%Y-%m-%d")
    print_message "No stream date (run stream.sh), dating the post today"
fi
DAY=$(date -j -f "%Y-%m-%d" "$DATE" +%e | tr -d ' ')
DATE_NAME="$(date -j -f "%Y-%m-%d" "$DATE" +"%B %d")$(day_suffix "$DAY"), $(date -j -f "%Y-%m-%d" "$DATE" +%Y)"

# Chapter marks from format.sh ("  - 'HH:MM:SS.mmm Title'" lines), empty if there are none
CHAPTERS_FILE="chapters-"$1".yml"
CHAPTERS=""
if [ -f "$CHAPTERS_FILE" ]; then
    CHAPTERS=$(< "$CHAPTERS_FILE")
fi

TOPICS_FILE="topics-"$1".md"
OUTPUT_FILE=""$DATE"-"$1".md"
rm -f "$OUTPUT_FILE" > "$LOG" 2>&1

HEADER=$(cat <<EOF
---
title: '$TITLE'
subtitle: ''
datum: $DATE_NAME
layout: post
author: Cowsay Crew ©
explicit: 'no'
duration: '$DURATION'
audio:
  mp3: $AUDIO_OBJECT_NAME
filesize:
  mp3: $AUDIO_SIZE
chapters:
$CHAPTERS
---

{% podigee_player page %}
$VIDEO_LINE
### Live-ul săptămânal Cowsay Show. Vă aducem o doză [ne]sănătoasă de speculații 🤗. 

Ne găsiți pe [Discord](https://discord.gg/UaNer3K), [Facebook](https://www.facebook.com/cowsayshow), [Youtube](https://youtube.com/@cowsay).<br>
Abonați-vă la [calendar](https://calendar.google.com/calendar/u/0cid=YTQ1NnUyNjRjNmlyMzFqcXIzZTQ2bHBrN2dAZ3JvdXAuY2FsZW5kYXIuZ29vZ2xlLmNvbQ) să nu ratați live-urile.<br>
De asemenea apreciem susținerea voastră pe [Patreon](https://www.patreon.com/cowsay)

### Temele săptămânii
EOF
)

FOOTER=$(cat <<EOF

### Temele ascultătorilor 
Colectăm teme de la voi pe canalul #topics din Discord. Iată aici - [https://discord.gg/GAYUppJUVX](https://discord.gg/GAYUppJUVX)

### Stand with Ukraine 🇺🇦 
Cowsay nu poate sta deoparte și noi am gătit o pagină specială - [https://cowsay.show/standwithukraine](https://cowsay.show/standwithukraine) unde puteți găsi fonduri care ajută Ucraina și Ucrainienii în diferite moduri la moment. Văd îndemnăm să donați și voi în măsura posibilităților. Războiul trebuie să se oprească. Agresorii trebuie să răspundă. 

### Patreon
Acum avem și noi ~~Onlyfans~~ **Patreon** Aici - [https://www.patreon.com/cowsay](https://www.patreon.com/cowsay) puteți ajuta dezvoltarea podcastului și primi beneficii exclusive pentru asta.
EOF
)

echo "$HEADER" >> "$OUTPUT_FILE"
cat "$TOPICS_FILE" >> "$OUTPUT_FILE"
echo "$FOOTER" >> "$OUTPUT_FILE"

cp "$OUTPUT_FILE" "$COWSAY_SOURCE""$OUTPUT_FILE" > "$LOG" 2>&1

print_success "New episode MD file has been created and copied over to cowsay_source dir"