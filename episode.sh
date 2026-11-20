#!/bin/zsh

# Run the whole post-show pipeline for one episode.
#
# Usage: ./episode.sh -e <number> -n <title> (-l <mp3> | -y <youtube_url>) [-u] [-t] [-r] [-v]

cd "${0:A:h}"

. ./messages.sh
. ./logging.sh
. ./vars.sh
. ./utils.sh

set -euo pipefail

USAGE="-e <number> -n <title> -l <mp3> | -y <url> [-u] [-t] [-r] [-v]"

# Default values
EPISODE_NUMBER=""
EPISODE_TITLE=""
YOUTUBE_URL=""
FILE_SOURCE=""
AUDIO_FLAGS=()     # only for audio.sh: -u -t
COMMON_FLAGS=()    # for audio.sh and topics.sh: -r -v
VERBOSE_FLAG=()    # for format.sh and publish.sh: -v

while getopts ":e:n:y:l:utrv" opt; do
  case ${opt} in
    e )
      EPISODE_NUMBER=$OPTARG
      ;;
    y )
      YOUTUBE_URL=$OPTARG
      ;;
    n )
      EPISODE_TITLE=$OPTARG
      ;;
    l )
      FILE_SOURCE=${OPTARG:A}
      ;;
    u )
      AUDIO_FLAGS+=(-u)
      ;;
    t )
      AUDIO_FLAGS+=(-t)
      ;;
    r )
      COMMON_FLAGS+=(-r)
      ;;
    v )
      COMMON_FLAGS+=(-v)
      VERBOSE_FLAG=(-v)
      set -x
      ;;
    \? )
      echo "Invalid option: -$OPTARG ($USAGE)" >&2
      exit 1
      ;;
    : )
      echo "Option -$OPTARG requires an argument ($USAGE)." >&2
      exit 1
      ;;
  esac
done

if [ -z "$EPISODE_NUMBER" ]; then
    print_error "This script needs episode number in order to work"
    exit 1
fi

if [ -z "$EPISODE_TITLE" ]; then
    print_error "This script needs episode title in order to work"
    exit 1
fi

# 1. Audio: raw -> transcript -> intro cut -> crop -> compress -> tag -> R2
if [ -n "$FILE_SOURCE" ]; then
    ./audio.sh -e "$EPISODE_NUMBER" -l "$FILE_SOURCE" "${AUDIO_FLAGS[@]}" "${COMMON_FLAGS[@]}"
elif [ -n "$YOUTUBE_URL" ]; then
    ./audio.sh -e "$EPISODE_NUMBER" -y "$YOUTUBE_URL" "${AUDIO_FLAGS[@]}" "${COMMON_FLAGS[@]}"
else
    print_error "This script needs either youtube url or local file source to work"
    exit 1
fi

# 2. Topics: transcript + Trello list -> Records-<ep>.csv
./topics.sh -e "$EPISODE_NUMBER" "${COMMON_FLAGS[@]}"

# 3. Review the topics before they go into the show notes
EPISODE_DIR="$COWSAY_DIR/$EPISODE_NUMBER"
REVIEW_FILE="$EPISODE_DIR/topics-$EPISODE_NUMBER.review.txt"
RECORDS_FILE="$EPISODE_DIR/Records-$EPISODE_NUMBER.csv"

if [ -f "$REVIEW_FILE" ]; then
    cat "$REVIEW_FILE"
else
    cat "$RECORDS_FILE"
fi
print_message "Use these topics? y / [n] / e to edit $RECORDS_FILE first"
read ANSWER

if [ "$ANSWER" = "e" ]; then
    open -t "$RECORDS_FILE"
    print_message "Edit and save the file, then press Enter to continue"
    read
elif [ "$ANSWER" != "y" ]; then
    print_error "Not using these topics. Run again with -r to regenerate them, or edit $RECORDS_FILE"
    exit 0
fi

# 4. Show notes, chapters, post, publish
./format.sh "$EPISODE_NUMBER" "${VERBOSE_FLAG[@]}"
./template-yt.sh "$EPISODE_NUMBER"
./template-md.sh "$EPISODE_NUMBER" "$EPISODE_TITLE"
./publish.sh "$EPISODE_NUMBER" "${VERBOSE_FLAG[@]}"
