#!/bin/zsh

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title cow template-yt
# @raycast.mode fullOutput

# Optional parameters:
# @raycast.icon 🎥
# @raycast.argument1 { "type": "text", "placeholder": "Episode Number" }
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
prepare_logging "youtube"

set -euo pipefail
# set -x

print_message "Preparing to execute the script"

# Check for episode number to be present
if [ -z "$1" ]; then
    print_error "This script needs episode number in order to work"
    exit 1
fi

# Check on OS

OS="$(uname -s)"

if [ $OS != "Darwin" ]; then
    print_message "This script is meant to be running on macOS"
    exit 1
fi

# Dirs

EPISODE_DIR=""$COWSAY_DIR"$1"

if [ ! -d "$EPISODE_DIR" ]; then
    mkdir -p "$EPISODE_DIR" > "$LOG" 2>&1
fi
cd "$EPISODE_DIR" > "$LOG" 2>&1

TOPICS_FILE="topics-"$1".txt"
OUTPUT_FILE="youtube-"$1".txt"
rm -f "$OUTPUT_FILE" > "$LOG" 2>&1

HEADER=$(cat <<EOF
Live-ul săptămânal Cowsay Show. Vă aducem o doză [ne]sănătoasă de speculații 🤗. 

Ne găsiți pe Discord: https://discord.gg/UaNer3K
pe Facebook: https://www.facebook.com/cowsayshow
pe Youtube: https://youtube.com/@cowsay
Abonați-vă la calendar să nu ratați live-urile: https://calendar.google.com/calendar/u/0?cid=YTQ1NnUyNjRjNmlyMzFqcXIzZTQ2bHBrN2dAZ3JvdXAuY2FsZW5kYXIuZ29vZ2xlLmNvbQ 
De asemenea apreciem susținerea voastră pe Patreon: https://www.patreon.com/cowsay

Temele săptămânii
EOF
)

FOOTER=$(cat <<EOF

Temele ascultătorilor 
Colectăm teme de la voi pe canalul #topics din Discord. Iată aici - https://discord.gg/GAYUppJUVX

Stand with Ukraine 🇺🇦 
Cowsay nu poate sta deoparte și noi am gătit o pagină specială - https://cowsay.show/standwithukraine unde puteți găsi fonduri care ajută Ucraina și Ucrainienii în diferite moduri la moment. Văd îndemnăm să donați și voi în măsura posibilităților. Războiul trebuie să se oprească. Agresorii trebuie să răspundă. 

Patreon
Acum avem și noi Patreon Aici - https://www.patreon.com/cowsay puteți ajuta dezvoltarea podcastului și primi beneficii exclusive pentru asta.
EOF
)

echo "$HEADER" >> "$OUTPUT_FILE"
cat "$TOPICS_FILE" >> "$OUTPUT_FILE"
echo "$FOOTER" >> "$OUTPUT_FILE"

pbcopy < "$OUTPUT_FILE" > "$LOG" 2>&1

print_success "Youtube(Facebook) show notes have been successfully created"