#!/bin/zsh

# Run the whole post-show pipeline for one episode, or for every unpublished one.
#
# Usage: ./episode.sh -e <number> [-n <title>] [-l <file> | -y <youtube_url>] [-u] [-t] [-r <steps>] [-v]
#        ./episode.sh -a [-u] [-t] [-r <steps>] [-v]
#
# Everything already built is reused on a rerun. -r <steps> redoes only those steps, comma separated:
#   stream  look the YouTube stream up again (stream.sh -r)
#   audio   rebuild the raw copy and the final mp3, keeping the cut (audio.sh -r)
#   cut     detect the intro cut again, replacing one set by hand (audio.sh -c)
#   topics  fetch the Trello cards and place the topics again: an LLM call (topics.sh -r)
#   align   measure the YouTube offset again (yt-align.sh -r)
#   all     all of them except cut (all,cut for that too)
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

USAGE="-e <number> [-n <title>] [-l <file> | -y <url>] [-u] [-t] [-r <steps>] [-v]  or  -a [-u] [-t] [-r <steps>] [-v]"

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
UPLOAD_TEST_FLAGS=()    # only for audio.sh: -u -t
REDO=""            # -r <steps>
VERBOSE_FLAG=()    # for every step: -v

while getopts ":e:an:y:l:utr:v" opt; do
  case ${opt} in
    e ) EPISODE_NUMBER=$OPTARG ;;
    a ) ALL=true ;;
    y ) YOUTUBE_URL=$OPTARG ;;
    n ) EPISODE_TITLE=$OPTARG ;;
    l ) FILE_SOURCE=${OPTARG:A} ;;
    u ) UPLOAD_TEST_FLAGS+=(-u) ;;
    t ) UPLOAD_TEST_FLAGS+=(-t) ;;
    r ) REDO=$OPTARG ;;
    v )
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

REDO_STEPS=(${(s:,:)REDO})
for step in "${REDO_STEPS[@]}"; do
    case $step in
        stream|audio|cut|topics|align|all ) ;;
        * ) usage_error "Unknown step for -r: $step (stream, audio, cut, topics, align or all)" ;;
    esac
done

# redo <step>: true if -r asked for this step (all covers everything but the cut)
redo() {
    if (( ${REDO_STEPS[(Ie)$1]} )); then return 0; fi
    [ "$1" != cut ] && (( ${REDO_STEPS[(Ie)all]} ))
}

STREAM_FLAGS=("${VERBOSE_FLAG[@]}")
AUDIO_FLAGS=("${UPLOAD_TEST_FLAGS[@]}" "${VERBOSE_FLAG[@]}")
TOPICS_FLAGS=("${VERBOSE_FLAG[@]}")
ALIGN_FLAGS=("${VERBOSE_FLAG[@]}")
if redo stream; then STREAM_FLAGS+=(-r); fi
if redo audio;  then AUDIO_FLAGS+=(-r); fi
if redo cut;    then AUDIO_FLAGS+=(-c); fi
if redo topics; then TOPICS_FLAGS+=(-r); fi
if redo align;  then ALIGN_FLAGS+=(-r); fi

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
    if headless; then
        ANSWER="${COWSAY_EPISODES:-}"    # y, or the numbers to publish
        [ -n "$ANSWER" ] || { echo "NEEDS_REVIEW: episodes (set COWSAY_EPISODES to y or the numbers)"; exit $NEEDS_REVIEW; }
    else
        print_message "Publish them? y / [n] / the numbers to publish (e.g. ${UNPUBLISHED[-1]})"
        read ANSWER
    fi
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
        if "./$SCRIPT_NAME" -e "$ep" ${UPLOAD_TEST_FLAGS[@]} ${REDO:+-r} ${REDO:+"$REDO"} ${VERBOSE_FLAG[@]}; then
            DONE+=("$ep")
        elif [ $? -eq $NEEDS_REVIEW ]; then
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
if ! ./stream.sh -e "$EPISODE_NUMBER" "${STREAM_FLAGS[@]}"; then
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
    ./audio.sh -e "$EPISODE_NUMBER" -l "$FILE_SOURCE" "${AUDIO_FLAGS[@]}"
else
    ./audio.sh -e "$EPISODE_NUMBER" -y "$YOUTUBE_URL" "${AUDIO_FLAGS[@]}"
fi

# 2. Topics: transcript + Trello cards and their links -> Records-<ep>.csv
REVIEW_FILE="$EPISODE_DIR/topics-$EPISODE_NUMBER.review.txt"
RECORDS_FILE="$EPISODE_DIR/Records-$EPISODE_NUMBER.csv"

if [ -f "$RECORDS_FILE" ] && ! redo topics; then
    print_message "Topics already placed in ${RECORDS_FILE:t}, not fetching the Trello cards again (-r topics does)"
elif ! ./trello.sh -e "$EPISODE_NUMBER" "${VERBOSE_FLAG[@]}"; then
    print_error "No Trello topics for episode $EPISODE_NUMBER, the topics will have no links (run ./trello.sh -e $EPISODE_NUMBER -l \"<list name>\" and then this again with -r topics)"
fi
./topics.sh -e "$EPISODE_NUMBER" "${TOPICS_FLAGS[@]}"

# 3. Review the topics before they go into the show notes

if ! { headless && approved topics; }; then    # an approved headless run doesn't print them again
    if [ -f "$REVIEW_FILE" ] && [ ! "$RECORDS_FILE" -nt "$REVIEW_FILE" ]; then    # Records edited by hand: show it
        cat "$REVIEW_FILE"
    else
        cat "$RECORDS_FILE"
    fi
fi
if headless; then
    gate topics "edit $RECORDS_FILE to fix them"
else
    print_message "Use these topics? y / [n] / e to edit $RECORDS_FILE first"
    read ANSWER

    if [ "$ANSWER" = "e" ]; then
        open -t "$RECORDS_FILE"
        print_message "Edit and save the file, then press Enter to continue"
        read
    elif [ "$ANSWER" != "y" ]; then
        print_error "Not using these topics. Run again with -r topics to regenerate them, or edit $RECORDS_FILE"
        exit $NEEDS_REVIEW
    fi
fi

# 4. Where the YouTube video starts against the raw audio, for its timestamps and captions
./yt-align.sh -e "$EPISODE_NUMBER" "${ALIGN_FLAGS[@]}"

# 5. Show notes, chapters, post, publish
./format.sh "$EPISODE_NUMBER" "${VERBOSE_FLAG[@]}"
./template-yt.sh "$EPISODE_NUMBER"
./template-md.sh "$EPISODE_NUMBER" "$EPISODE_TITLE"
./publish.sh "$EPISODE_NUMBER" "${VERBOSE_FLAG[@]}"

# 6. YouTube: description, tags, category, playlist, captions (skipped until youtube-auth.sh was run)
./youtube-update.sh -e "$EPISODE_NUMBER" "${VERBOSE_FLAG[@]}"
