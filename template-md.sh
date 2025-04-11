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

# Prepare the logs
prepare_logging "markdown"

set -euo pipefail
# set -x

print_message "Preparing to execute the script"

# Check for episode number to be present
if [ -z "$1" ]; then
    print_error "This script needs episode number in order to work"
    exit 1
fi

# Check for episode number to be present
if [ -z "$2" ]; then
    print_error "This script needs episode title in order to work"
    exit 1
fi

# Check on OS

OS="$(uname -s)"

if [ $OS != "Darwin" ]; then
    print_error "This script is meant to be running on macOS"
    exit 1
fi

# Dirs

EPISODE_DIR=""$COWSAY_DIR"$1"

if [ ! -d "$EPISODE_DIR" ]; then
    mkdir -p "$EPISODE_DIR" > "$LOG" 2>&1
fi
cd "$EPISODE_DIR" > "$LOG" 2>&1

day_suffix() {
  case `date +%d` in
    1|21|31) echo "st";;
    2|22)    echo "nd";;
    3|23)    echo "rd";;
    *)       echo "th";;
  esac
}

TITLE="$2"
AUDIO_FILE_NAME="cow"$1".mp3"
DURATION=$(ffprobe -i "$AUDIO_FILE_NAME" -show_entries format=duration -v quiet -of csv="p=0" -sexagesimal)
DATE=$(date +"%Y-%m-%d")
DATE_NAME=$(date +"%B %d`day_suffix`, %Y")
AUDIO_SIZE=$(ls -l "$AUDIO_FILE_NAME" | cut -d ' ' -f 7)

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
duration: '${DURATION:0:-7}'
audio:
  mp3: $AUDIO_FILE_NAME
filesize:
  mp3: $AUDIO_SIZE
chapters:
---

{% podigee_player page %}

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

cp "$OUTPUT_FILE" ~/Code/Personal/cowsay-source/_posts/"$OUTPUT_FILE" > "$LOG" 2>&1

print_success "New episode MD file has been created and copied over to cowsay_source dir"