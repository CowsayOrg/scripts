#!/bin/zsh

# Find when each topic starts, using the episode transcript and the Trello topic list,
# and write Records-<ep>.csv in the format format.sh reads (same as the old Records app export).
#
# Usage: ./topics.sh -e <episode> [-r] [-v]
#
# Inputs (in $COWSAY_DIR/<ep>/):
#   transcript-<ep>.txt      podcast-timeline transcript (written by audio.sh)
#   transcript-<ep>.json     same, normalized JSON (used for validation)
#   trello_cards_<ep>.ssv    planned topics from trello.sh (optional)
# Outputs:
#   Records-<ep>.csv         "HH:MM:SS.mmm","Title","link" rows, Intro first and Outro last
#   topics-<ep>.llm.json     raw LLM answer
#   topics-<ep>.review.txt   readable summary for the review step
#
# An existing Records-<ep>.csv (for example a manual export) is kept unless -r is given.

SCRIPTS_DIR="${0:A:h}"
cd "$SCRIPTS_DIR"

. ./messages.sh
. ./logging.sh
. ./vars.sh
. ./utils.sh
. ./transcript.sh

set -euo pipefail

EPISODE_NUMBER=""
REWRITE=false

while getopts ":e:rv" opt; do
    case ${opt} in
        e ) EPISODE_NUMBER=$OPTARG ;;
        r ) REWRITE=true ;;
        v ) set -x ;;
        \? ) echo "Invalid option: -$OPTARG (-e <episode> [-r] [-v])" >&2; exit 1 ;;
        : ) echo "Option -$OPTARG requires an argument (-e <episode> [-r] [-v])" >&2; exit 1 ;;
    esac
done

if [ -z "$EPISODE_NUMBER" ]; then
    print_error "This script needs episode number in order to work"
    exit 1
fi

prepare_logging "topics"
prepare_dir "$EPISODE_NUMBER"

TRANSCRIPT_TXT="transcript-$EPISODE_NUMBER.txt"
TRANSCRIPT_JSON="transcript-$EPISODE_NUMBER.json"
TRELLO_FILE="trello_cards_$EPISODE_NUMBER.ssv"
RECORDS="Records-$EPISODE_NUMBER.csv"
LLM_ANSWER="topics-$EPISODE_NUMBER.llm.json"
REVIEW="topics-$EPISODE_NUMBER.review.txt"
PROMPT_FILE="topics-$EPISODE_NUMBER.prompt.txt"

if [ -f "$RECORDS" ] && [ "$REWRITE" = false ]; then
    print_message "$RECORDS already exists, keeping it (use -r to regenerate it from the transcript)"
    exit 0
fi

for f in "$TRANSCRIPT_TXT" "$TRANSCRIPT_JSON"; do
    if [ ! -f "$f" ]; then
        print_error "$f not found in $EPISODE_DIR. Run audio.sh first"
        exit 1
    fi
done

# Planned topics: "name†url1;url2" -> [{title, link}]
if [ -f "$TRELLO_FILE" ]; then
    TOPICS=$(jq -R 'select(length > 0) | split("†")
                    | { title: .[0], link: ((.[1] // "") | split(";") | map(select(length > 0)) | first // null) }' \
                "$TRELLO_FILE" | jq -s .)
    print_message "Planned topics from $TRELLO_FILE: $(jq length <<< "$TOPICS")"
else
    TOPICS="[]"
    print_error "$TRELLO_FILE not found, the LLM will discover the topics on its own (no links)"
fi

fill_template "$SCRIPTS_DIR/prompts/topics.md" \
    TOPICS "$TOPICS" \
    TRANSCRIPT "$(< "$TRANSCRIPT_TXT")" > "$PROMPT_FILE"

print_message "Asking Claude to place the topics on the timeline ($LLM_MODEL)... this takes a minute or two"
if ! claude_json "$PROMPT_FILE" "$SCRIPTS_DIR/prompts/topics.schema.json" > "$LLM_ANSWER"; then
    print_error "Topic detection failed, see $LLM_ANSWER and $LOG"
    exit 1
fi
rm -f "$PROMPT_FILE"

# Validate: every discussed topic has a start inside the audio
DURATION=$(jq '[ .segments[].end ] | max' "$TRANSCRIPT_JSON")
PROBLEMS=$(jq -r --argjson dur "$DURATION" "$JQ_TIME"'
    [ (.topics[] | select(.skipped | not)
        | if .start == null then "no start time for \"\(.title)\""
          elif (.start | secs) > $dur then "\"\(.title)\" starts at \(.start), after the end of the audio"
          else empty end),
      (if (.outro | secs) > $dur then "outro \(.outro) is after the end of the audio" else empty end) ]
    | .[]
' "$LLM_ANSWER")
if [ -n "$PROBLEMS" ]; then
    print_error "The LLM answer has problems:"
    print -r -- "$PROBLEMS" >&2
    exit 1
fi

# Refine: the LLM only sees ~30 s blocks, so find its evidence quote in the segment-level
# transcript and use that segment's exact start. Falls back to the block time if not found.
TIMED="topics-$EPISODE_NUMBER.timed.json"
jq --slurpfile tr "$TRANSCRIPT_JSON" --argjson block "${TRANSCRIPT_BLOCK:-10}" "$JQ_TIME"'
    def norm: ascii_downcase | gsub("[^\\p{L}\\p{N} ]"; "") | gsub(" +"; " ") | ltrimstr(" ");
    def key: norm | split(" ") | .[:4] | join(" ");
    $tr[0].segments as $segs
    | .topics |= map(
        if .skipped or .start == null then .
        else (.start | secs) as $t | (.evidence | key) as $k
            | ([ $segs[] | select(.start >= $t - 1 and .start < $t + $block + 1)
                         | select($k | length >= 6) | select(.text | norm | contains($k)) ] | first) as $hit
            | .seconds = (if $hit then $hit.start else $t end)
            | .refined = ($hit != null)
        end)
    | .outro_seconds = (.outro | secs)
' "$LLM_ANSWER" > "$TIMED"

# Records CSV: Intro at 0 (the audio is already cropped), topics in order, Outro last
jq -r "$JQ_TIME"'
    ([ .topics[] | select(.skipped | not) ] | sort_by(.seconds)) as $t
    | ([ [ "00:00:00.000", "Intro" ] ]
       + [ $t[] | [ (.seconds | hmsms), .title ] + (if .link then [ .link ] else [] end) ]
       + [ [ (.outro_seconds | hmsms), "Outro" ] ])
    | .[] | @csv
' "$TIMED" > "$RECORDS"

# Review summary
{
    print "Topics found for episode $EPISODE_NUMBER (podcast time):"
    print ""
    jq -r "$JQ_TIME"'
        ([ .topics[] | select(.skipped | not) ] | sort_by(.seconds)) as $t
        | "  00:00:00  Intro",
          ($t[] | "  \(.seconds | hms)  \(.title)\(if .planned then "" else "   [unplanned]" end)\n            «\(.evidence)»"),
          "  \(.outro)  Outro",
          "",
          ([ .topics[] | select(.skipped) ] | if length > 0 then "Skipped (not discussed):", (.[] | "  - \(.title)") else empty end)
    ' "$TIMED"
} > "$REVIEW"

print_success "Topics placed: $RECORDS ($(jq '[ .topics[] | select(.skipped | not) ] | length' "$TIMED") topics, $(jq '[ .topics[] | select(.refined) ] | length' "$TIMED") refined to the exact phrase) 🐮"
