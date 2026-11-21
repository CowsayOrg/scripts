#!/bin/zsh

# Give an already published episode its YouTube show notes (topics with links and chapters), without
# its audio and without a paid transcription: the topics are placed on YouTube's automatic captions.
# The site post is not changed.
#
# Usage: ./youtube-notes.sh -e <episode> [-t "<title>"] [-r] [-n] [-v]
#   -t  also rename the videos (youtube-update.sh -t)
#   -r  place the topics again even if Records-<ep>.csv exists (an old manual one is kept otherwise)
#   -n  dry run of the YouTube update
#
# Steps: stream.sh, the captions as transcript-<ep>.raw.json (providers/youtube.sh, on the video
# timeline, so cut and YouTube offset are 0), the planned topics (trello.sh, or the post's topic list
# when there is no Trello list), topics.sh, format.sh, template-yt.sh, youtube-update.sh.

SCRIPTS_DIR="${0:A:h}"
cd "$SCRIPTS_DIR"

. ./messages.sh
. ./logging.sh
. ./vars.sh
. ./utils.sh
. ./transcript.sh
. ./r2.sh
. ./yt-helpers.sh
. ./providers/youtube.sh

set -euo pipefail

EPISODE_NUMBER=""
TITLE=""
REWRITE=false
UPDATE_FLAGS=()
VERBOSE_FLAG=()

while getopts ":e:t:rnv" opt; do
    case ${opt} in
        e ) EPISODE_NUMBER=$OPTARG ;;
        t ) TITLE=$OPTARG ;;
        r ) REWRITE=true ;;
        n ) UPDATE_FLAGS+=(-n) ;;
        v ) set -x; VERBOSE_FLAG=(-v) ;;
        * ) echo "Usage: $0 -e <episode> [-t \"<title>\"] [-r] [-n] [-v]" >&2; exit 1 ;;
    esac
done

if [ -z "$EPISODE_NUMBER" ]; then
    print_error "This script needs episode number in order to work"
    exit 1
fi

EP="$EPISODE_NUMBER"
"$SCRIPTS_DIR/stream.sh" -e "$EP" ${VERBOSE_FLAG[@]}

prepare_logging "youtube-notes"
prepare_dir "$EP"

RECORDS="Records-$EP.csv"
if [ -f "$RECORDS" ] && [ "$REWRITE" = false ]; then
    print_message "Using the existing $RECORDS (-r to place the topics again)"
else
    # Transcript: the captions, on the video timeline
    if [ ! -s "transcript-$EP.raw.json" ] || [ "$REWRITE" = true ]; then
        youtube_captions_transcript "$(jq -r '.url' "stream-$EP.json")" "transcript-$EP.raw.json"
    fi
    if [ "$(jq -r '.provider // empty' "transcript-$EP.raw.json")" != youtube ]; then
        print_error "transcript-$EP.raw.json is from the audio, not the captions: run the normal pipeline (episode.sh) instead"
        exit 1
    fi
    shift_transcript "transcript-$EP.raw.json" "transcript-$EP.json" 0
    transcript_to_text "transcript-$EP.json" "transcript-$EP.txt"
    print -r -- 0 > "cut-$EP.txt"
    print -r -- "captions"$'\t'"the transcript is YouTube's own captions" > "cut-$EP.info"
    print -r -- 0.000 > "youtube-offset-$EP.txt"
    print -r -- "captions"$'\t'"the transcript is YouTube's own captions" > "youtube-offset-$EP.info"

    # Planned topics: Trello, or the topic list of the post
    if ! "$SCRIPTS_DIR/trello.sh" -e "$EP" ${VERBOSE_FLAG[@]}; then
        POST=$(find_post "$EP")
        if [ -z "$POST" ]; then
            print_error "No Trello list and no post for episode $EP, the LLM finds the topics on its own"
        else
            print_message "Using the topics of $POST:t instead"
            sed -n '/^### Temele săptămânii/,/^### /p' "$POST" | grep '^\* ' | jq -R '
                sub("^\\* "; "") as $l
                | [ $l | match("\\]\\((https?://[^)]+)\\)"; "g") | .captures[0].string ] as $links
                | { name: ($l | gsub("\\]\\([^)]*\\)"; "") | gsub("[\\[\\]]"; "") | sub("\\s*\\((link[0-9]+(, )?)+\\)$"; "")), links: $links, desc: "" }' \
                | jq -s --arg p "$POST:t" '{ list: { id: null, name: ("post " + $p) }, cards: . }' > "trello-$EP.json"
        fi
    fi

    "$SCRIPTS_DIR/topics.sh" -e "$EP" -r ${VERBOSE_FLAG[@]}
    cat "topics-$EP.review.txt"
fi

cd "$SCRIPTS_DIR"
./format.sh "$EP"
./template-yt.sh "$EP" > /dev/null
[ -n "$TITLE" ] && UPDATE_FLAGS+=(-t "$TITLE")
"$SCRIPTS_DIR/youtube-update.sh" -e "$EP" ${UPDATE_FLAGS[@]} ${VERBOSE_FLAG[@]}
