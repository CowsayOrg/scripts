#!/bin/zsh

# Run the whole post-show pipeline for one episode, or for every unpublished one.
#
# Usage: ./episode.sh -e <number> [-n <title>] [-l <file> | -y <youtube_url>] [-u] [-t] [-r] [-v]
#        ./episode.sh -a [-u] [-t] [-r] [-v]
#
# With -e, the title and the YouTube stream are looked up on the channel (stream.sh) and the
# recording is found on disk (find-audio.sh) or downloaded from the stream. -n, -l and -y override them.
# With -a, every episode streamed on YouTube but missing on cowsay.show (unpublished.sh) is run in turn.

SCRIPT_NAME="${0:t}"
cd "${0:A:h}"

. ./messages.sh
. ./logging.sh
. ./vars.sh
. ./utils.sh

set -euo pipefail

USAGE="-e <number> [-n <title>] [-l <file> | -y <url>] [-u] [-t] [-r] [-v]  or  -a [-u] [-t] [-r] [-v]"
REVIEW_DECLINED=3    # exit code when the topics are not accepted

usage_error() {
    print_error "$1"
    echo "Usage: ./$SCRIPT_NAME $USAGE" >&2
    exit 1
}

# Default values
EPISODE_NUMBER=""
ALL=false
EPISODE_TITLE=""
YOUTUBE_URL=""
FILE_SOURCE=""
AUDIO_FLAGS=()     # only for audio.sh: -u -t
COMMON_FLAGS=()    # for audio.sh, topics.sh, stream.sh: -r -v
VERBOSE_FLAG=()    # for format.sh and publish.sh: -v

while getopts ":e:an:y:l:utrv" opt; do
  case ${opt} in
    e ) EPISODE_NUMBER=$OPTARG ;;
    a ) ALL=true ;;
    y ) YOUTUBE_URL=$OPTARG ;;
    n ) EPISODE_TITLE=$OPTARG ;;
    l ) FILE_SOURCE=${OPTARG:A} ;;
    u ) AUDIO_FLAGS+=(-u) ;;
    t ) AUDIO_FLAGS+=(-t) ;;
    r ) COMMON_FLAGS+=(-r) ;;
    v )
      COMMON_FLAGS+=(-v)
      VERBOSE_FLAG=(-v)
      set -x
      ;;
    \? ) usage_error "Invalid option: -$OPTARG" ;;
    : )  usage_error "Option -$OPTARG requires an argument" ;;
  esac
done

if [ "$ALL" = true ] && [ -n "$EPISODE_NUMBER$EPISODE_TITLE$FILE_SOURCE$YOUTUBE_URL" ]; then
    usage_error "-a can't be combined with -e, -n, -l or -y"
fi
if [ "$ALL" = false ] && [ -z "$EPISODE_NUMBER" ]; then
    usage_error "Give an episode number (-e <number>) or -a to publish all unpublished episodes"
fi
if [ -n "$FILE_SOURCE" ] && [ -n "$YOUTUBE_URL" ]; then
    usage_error "Give either -l or -y, not both"
fi

##################################################################################
# -a: run every unpublished episode, oldest first

if [ "$ALL" = true ]; then
    print_message "Looking for episodes streamed on YouTube but not published on cowsay.show..."
    UNPUBLISHED=(${(f)"$(./unpublished.sh)"})
    if [ ${#UNPUBLISHED} -eq 0 ]; then
        print_success "Everything is published 🐮"
        exit 0
    fi

    print_message "Unpublished: ${(j:, :)UNPUBLISHED}"
    print_message "Publish them? y / [n] / the numbers to publish (e.g. ${UNPUBLISHED[-1]})"
    read ANSWER
    if [ "$ANSWER" = "y" ]; then
        SELECTED=("${UNPUBLISHED[@]}")
    elif [[ "$ANSWER" =~ ^[0-9[:space:],]+$ ]]; then
        SELECTED=()
        for ep in ${=ANSWER//,/ }; do
            if (( ${UNPUBLISHED[(Ie)$ep]} )); then SELECTED+=("$ep"); else print_error "$ep is not in the list, ignoring it"; fi
        done
    else
        print_message "Nothing published"
        exit 0
    fi

    DONE=(); STOPPED=(); FAILED=()
    for ep in "${SELECTED[@]}"; do
        print_message "=== Episode $ep ==="
        if "./$SCRIPT_NAME" -e "$ep" "${AUDIO_FLAGS[@]}" "${COMMON_FLAGS[@]}"; then
            DONE+=("$ep")
        elif [ $? -eq $REVIEW_DECLINED ]; then
            STOPPED+=("$ep")
        else
            FAILED+=("$ep")
            print_error "Episode $ep failed, continuing with the next one"
        fi
    done

    print_message "Done: ${(j:, :)DONE:-none}. Stopped at the review: ${(j:, :)STOPPED:-none}. Failed: ${(j:, :)FAILED:-none}"
    [ ${#FAILED} -eq 0 ]
    exit $?
fi

##################################################################################
# -e: one episode

EPISODE_DIR="$COWSAY_DIR/$EPISODE_NUMBER"
STREAM_FILE="$EPISODE_DIR/stream-$EPISODE_NUMBER.json"

# 0. Title and source: from the arguments, otherwise from the YouTube stream and the disk
if ! ./stream.sh -e "$EPISODE_NUMBER" "${COMMON_FLAGS[@]}"; then
    if [ -z "$EPISODE_TITLE" ] || [ -z "$FILE_SOURCE$YOUTUBE_URL" ]; then
        exit 1
    fi
fi

if [ -z "$EPISODE_TITLE" ]; then
    EPISODE_TITLE=$(jq -r '.title' "$STREAM_FILE")
fi

if [ -z "$FILE_SOURCE$YOUTUBE_URL" ]; then
    FILE_SOURCE=$(./find-audio.sh -e "$EPISODE_NUMBER" "${VERBOSE_FLAG[@]}")
    if [ -z "$FILE_SOURCE" ]; then
        YOUTUBE_URL=$(jq -r '.url' "$STREAM_FILE")
        print_message "Will download the audio from $YOUTUBE_URL"
    fi
fi

print_message "Episode $EPISODE_NUMBER: \"$EPISODE_TITLE\", source: ${FILE_SOURCE:-$YOUTUBE_URL}"

# 1. Audio: raw -> transcript -> intro cut -> crop -> compress -> tag -> R2
if [ -n "$FILE_SOURCE" ]; then
    ./audio.sh -e "$EPISODE_NUMBER" -l "$FILE_SOURCE" "${AUDIO_FLAGS[@]}" "${COMMON_FLAGS[@]}"
else
    ./audio.sh -e "$EPISODE_NUMBER" -y "$YOUTUBE_URL" "${AUDIO_FLAGS[@]}" "${COMMON_FLAGS[@]}"
fi

# 2. Topics: transcript + Trello cards and their links -> Records-<ep>.csv
if ! ./trello.sh -e "$EPISODE_NUMBER" "${VERBOSE_FLAG[@]}"; then
    print_error "No Trello topics for episode $EPISODE_NUMBER, the topics will have no links (run ./trello.sh -e $EPISODE_NUMBER -l \"<list name>\" and then this again with -r)"
fi
./topics.sh -e "$EPISODE_NUMBER" "${COMMON_FLAGS[@]}"

# 3. Review the topics before they go into the show notes
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
    exit $REVIEW_DECLINED
fi

# 4. Where the YouTube video starts against the raw audio, for its timestamps and captions
./yt-align.sh -e "$EPISODE_NUMBER" "${COMMON_FLAGS[@]}"

# 5. Show notes, chapters, post, publish
./format.sh "$EPISODE_NUMBER" "${VERBOSE_FLAG[@]}"
./template-yt.sh "$EPISODE_NUMBER"
./template-md.sh "$EPISODE_NUMBER" "$EPISODE_TITLE"
./publish.sh "$EPISODE_NUMBER" "${VERBOSE_FLAG[@]}"

# 6. YouTube: description, tags, category, playlist, captions (skipped until youtube-auth.sh was run)
./youtube-update.sh -e "$EPISODE_NUMBER" "${VERBOSE_FLAG[@]}"
