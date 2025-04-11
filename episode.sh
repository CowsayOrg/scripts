#!/bin/zsh

# set -x
set -euo pipefail

# Default values
EPISODE_NUMBER=""
EPISODE_TITLE=""
YOUTUBE_URL=""
FILE_SOURCE=""
UPLOAD=""

UPLOAD_ARGUMENT=""

while getopts ":e:t:y:s:u" opt; do
  case ${opt} in
    e )
      EPISODE_NUMBER=$OPTARG
      ;;
    y )
      YOUTUBE_URL=$OPTARG
      ;;
    t )
      EPISODE_TITLE=$OPTARG
      ;;
    s )
      FILE_SOURCE=$OPTARG
      ;;
    u )
      UPLOAD="-u"
      ;;
    \? )
      echo "Invalid option: -$OPTARG (-e -t [-y])" >&2
      exit 1
      ;;
    : )
      echo "Option -$OPTARG requires an argument (-e -t [-y])." >&2
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

./format.sh "$EPISODE_NUMBER"

if [ -n "$FILE_SOURCE" ]; then
    ./audio.sh -e "$EPISODE_NUMBER" -l "$FILE_SOURCE" "$UPLOAD"
elif [ -n "$YOUTUBE_URL" ]; then
    ./audio.sh -e "$EPISODE_NUMBER" -y "$YOUTUBE_URL" "$UPLOAD"
else
    print_error "This script needs either youtube ulr or local file source to work"
    exit 1
fi

./template-yt.sh "$EPISODE_NUMBER"
./template-md.sh "$EPISODE_NUMBER" "$EPISODE_TITLE"
./publish.sh "$EPISODE_NUMBER"


