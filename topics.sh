#!/bin/zsh

# Find when each topic starts, using the episode transcript and the Trello topic list,
# and write Records-<ep>.csv in the format format.sh reads (same as the old Records app export).
#
# Usage: ./topics.sh -e <episode> [-r] [-v]
#
# Inputs (in $COWSAY_DIR/<ep>/):
#   transcript-<ep>.txt      podcast-timeline transcript (written by audio.sh)
#   transcript-<ep>.json     same, normalized JSON (used for validation)
#   trello-<ep>.json         planned topics (Trello cards) and their links, from trello.sh (optional;
#                            the old trello_cards_<ep>.ssv is read too)
# Outputs:
#   Records-<ep>.csv         "HH:MM:SS.mmm","Title","link1 link2" rows, Intro first and Outro last
#   Records-<ep>.cut         the cut these times are based on (audio.sh moves them when the cut changes)
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
TRELLO_JSON="trello-$EPISODE_NUMBER.json"
TRELLO_FILE="trello_cards_$EPISODE_NUMBER.ssv"    # old export format
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

# Planned topics: trello-<ep>.json (trello.sh), or the old trello_cards_<ep>.ssv ("name†url1;url2")
if [ -s "$TRELLO_JSON" ]; then
    CARDS=$(jq '[ .cards[] | { name, links } ]' "$TRELLO_JSON")
    NOTES=$(jq '[ .cards[] | .desc | .[0:300] ]' "$TRELLO_JSON")
    print_message "Planned topics from $TRELLO_JSON ($(jq -r '.list.name' "$TRELLO_JSON")): $(jq length <<< "$CARDS")"
elif [ -f "$TRELLO_FILE" ]; then
    CARDS=$(jq -R 'select(length > 0) | split("†")
                   | { name: .[0], links: ((.[1] // "") | split(";") | map(select(length > 0))) }' "$TRELLO_FILE" | jq -s .)
    NOTES=$(jq 'map("")' <<< "$CARDS")
    print_message "Planned topics from $TRELLO_FILE: $(jq length <<< "$CARDS")"
else
    CARDS="[]"
    NOTES="[]"
    print_error "No Trello topics (run trello.sh), the LLM will discover the topics on its own (no links)"
fi
TOPICS=$(jq -n --argjson c "$CARDS" --argjson n "$NOTES" '[ $c | to_entries[] | { card: .key, name: .value.name, notes: $n[.key] } ]')

fill_template "$SCRIPTS_DIR/prompts/topics.md" \
    TOPICS "$TOPICS" \
    TRANSCRIPT "$(< "$TRANSCRIPT_TXT")" > "$PROMPT_FILE"

print_message "Asking Claude to place the topics on the timeline ($LLM_MODEL)... this takes a minute or two"
if ! claude_json "$PROMPT_FILE" "$SCRIPTS_DIR/prompts/topics.schema.json" > "$LLM_ANSWER"; then
    print_error "Topic detection failed, see $LLM_ANSWER and $LOG"
    exit 1
fi
rm -f "$PROMPT_FILE"

# Validate: every start inside the audio, every card number on the list
DURATION=$(jq '[ .segments[].end ] | max' "$TRANSCRIPT_JSON")
PROBLEMS=$(jq -r --argjson dur "$DURATION" --argjson n "$(jq length <<< "$CARDS")" "$JQ_TIME"'
    [ (.topics[]
        | if (.start | secs) > $dur then "\"\(.title)\" starts at \(.start), after the end of the audio"
          elif .card != null and (.card < 0 or .card >= $n) then "\"\(.title)\" refers to card \(.card), there are \($n)"
          else empty end),
      (if (.outro | secs) > $dur then "outro \(.outro) is after the end of the audio" else empty end) ]
    | .[]
' "$LLM_ANSWER")
if [ -n "$PROBLEMS" ]; then
    print_error "The LLM answer has problems:"
    print -r -- "$PROBLEMS" >&2
    exit 1
fi

# Refine: the LLM only sees ~10 s blocks, so find its evidence quote in the segment-level
# transcript and use that segment's exact start. Falls back to the block time if not found.
# Links: the card's links, copied here from Trello (the LLM never writes URLs).
TIMED="topics-$EPISODE_NUMBER.timed.json"
jq --slurpfile tr "$TRANSCRIPT_JSON" --argjson cards "$CARDS" --argjson block "${TRANSCRIPT_BLOCK:-10}" "$JQ_TIME"'
    def norm: ascii_downcase | gsub("[^\\p{L}\\p{N} ]"; "") | gsub(" +"; " ") | ltrimstr(" ");
    def key: norm | split(" ") | .[:4] | join(" ");
    $tr[0].segments as $segs
    | .topics |= map(
        (.start | secs) as $t | (.evidence | key) as $k
        | ([ $segs[] | select(.start >= $t - 1 and .start < $t + $block + 1)
                     | select($k | length >= 6) | select(.text | norm | contains($k)) ] | first) as $hit
        | .seconds = (if $hit then $hit.start else $t end)
        | .refined = ($hit != null)
        | .planned = (.card != null)
        | .card_name = (if .card != null then $cards[.card].name else null end)
        | .links = (if .card != null then $cards[.card].links else [] end))
    | .skipped = [ .skipped_cards[] | select(. >= 0 and . < ($cards | length)) | $cards[.].name ]
    | .outro_seconds = (.outro | secs)
' "$LLM_ANSWER" > "$TIMED"

# Records CSV: Intro at 0 (the audio is already cropped), topics in order, Outro last.
# The third column holds the topic links separated by spaces (format.sh renders them).
jq -r "$JQ_TIME"'
    (.topics | sort_by(.seconds)) as $t
    | ([ [ "00:00:00.000", "Intro" ] ]
       + [ $t[] | [ (.seconds | hmsms), .title ] + (if (.links | length) > 0 then [ .links | join(" ") ] else [] end) ]
       + [ [ (.outro_seconds | hmsms), "Outro" ] ])
    | .[] | @csv
' "$TIMED" > "$RECORDS"
jq -r '.offset // 0' "$TRANSCRIPT_JSON" > "Records-$EPISODE_NUMBER.cut"

# Review summary
{
    print "Topics found for episode $EPISODE_NUMBER (podcast time):"
    print ""
    jq -r "$JQ_TIME"'
        (.topics | sort_by(.seconds)) as $t
        | "  00:00:00  Intro",
          ($t[] | "  \(.seconds | hms)  \(.title)"
                  + (if .planned then "\n            card: \(.card_name) (\(.links | length) link\(if (.links | length) == 1 then "" else "s" end))" else "\n            [no card, no links]" end)
                  + "\n            «\(.evidence)»"),
          "  \(.outro)  Outro",
          "",
          (.skipped | if length > 0 then "Cards not discussed:", (.[] | "  - \(.)") else empty end)
    ' "$TIMED"
} > "$REVIEW"

print_success "Topics placed: $RECORDS ($(jq '.topics | length' "$TIMED") topics, $(jq '[ .topics[] | select(.refined) ] | length' "$TIMED") refined to the exact phrase, $(jq '[ .topics[] | select(.planned) ] | length' "$TIMED") with a Trello card) 🐮"
