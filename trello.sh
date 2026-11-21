#!/bin/zsh

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title cow trello
# @raycast.mode fullOutput

# Optional parameters:
# @raycast.icon 📝
# @raycast.argument1 { "type": "text", "placeholder": "List Name" }
# @raycast.argument2 { "type": "text", "placeholder": "Episode Number" }
# @raycast.packageName cowsay-audio
# @raycast.needsConfirmation true

# Documentation:
# @raycast.description export the episode's Trello topics and their links
# @raycast.author vladd
# @raycast.authorURL https://raycast.com/vladd

# Export the episode's Trello cards (the planned topics) with all their links.
#
# Usage: ./trello.sh -e <episode> [-l "<list name>"] [-v]
#        ./trello.sh "<list name>" <episode>      (old form, still works)
#
# Without -l the list is found by the stream date (stream-<ep>.json, from stream.sh): the board has
# one list per show named after its date ("Nov 20", "28 July", "16th of September", "8 окт"...).
# Archived lists are searched too. Among lists with that day and month, the one created last
# before the stream wins.
#
# Links of a card: its attachments, then the URLs in its description (only the first one when there are
# more than 3 different ones: that's a pasted article, not a list of sources), without duplicates and
# without $TRELLO_LINK_EXCLUDE (private prep notes: Google Docs, chatgpt.site pages, uploads).
#
# Output: trello-<ep>.json  { list: {id, name}, cards: [ {name, links: [...], desc} ] }

SCRIPTS_DIR="${0:A:h}"
cd "$SCRIPTS_DIR"

. ./messages.sh
. ./vars.sh
. ./secrets.sh
. ./logging.sh
. ./utils.sh

set -euo pipefail

EPISODE_NUMBER=""
LIST_NAME=""

if [ $# -eq 2 ] && [[ "$1" != -* ]]; then    # old form: "<list name>" <episode>
    LIST_NAME="$1"
    EPISODE_NUMBER="$2"
else
    while getopts ":e:l:v" opt; do
        case ${opt} in
            e ) EPISODE_NUMBER=$OPTARG ;;
            l ) LIST_NAME=$OPTARG ;;
            v ) set -x ;;
            * ) echo "Usage: $0 -e <episode> [-l \"<list name>\"] [-v]" >&2; exit 1 ;;
        esac
    done
fi

if [ -z "$EPISODE_NUMBER" ]; then
    print_error "This script needs episode number in order to work"
    exit 1
fi
if ! command -v jq > /dev/null 2>&1; then
    print_error "jq is not installed. Please install it to continue"
    exit 1
fi

prepare_logging "trello"
prepare_dir "$EPISODE_NUMBER"

OUTPUT="trello-$EPISODE_NUMBER.json"
STREAM_FILE="stream-$EPISODE_NUMBER.json"
API="https://api.trello.com/1"

trello_get() {
    local response
    if ! response=$(curl -sf -G "$API/$1" --data-urlencode "key=$API_KEY" --data-urlencode "token=$TOKEN" "${@:2}"); then
        print_error "Trello request failed: $1"
        return 1
    fi
    print -r -- "$response"
}

LISTS=$(trello_get "boards/$TRELLO_BOARD_ID/lists" --data-urlencode "filter=all" --data-urlencode "fields=name,closed")

if [ -n "$LIST_NAME" ]; then
    LIST=$(jq -c --arg n "$LIST_NAME" '[ .[] | select(.name == $n) ] | last // empty' <<< "$LISTS")
    if [ -z "$LIST" ]; then
        print_error "List '$LIST_NAME' not found on the board"
        exit 1
    fi
else
    if [ ! -s "$STREAM_FILE" ] || [ -z "$(jq -r '.streamed_at // empty' "$STREAM_FILE")" ]; then
        "$SCRIPTS_DIR/stream.sh" -e "$EPISODE_NUMBER" > /dev/null 2>&1 || true    # gets the stream date
    fi
    STREAMED_AT=$(jq -r '.streamed_at // empty' "$STREAM_FILE" 2>/dev/null || true)
    if [ -z "$STREAMED_AT" ]; then
        print_error "No stream date for episode $EPISODE_NUMBER, can't find its Trello list. Give the list name: -l \"<name>\""
        exit 1
    fi
    DAY=$(TZ="$SHOW_TIMEZONE" date -r "$STREAMED_AT" +%e | tr -d ' ')
    MONTH=$(TZ="$SHOW_TIMEZONE" date -r "$STREAMED_AT" +%m | sed 's/^0//')

    LIST=$(jq -c --argjson day "$DAY" --argjson month "$MONTH" --argjson ts "$STREAMED_AT" '
        def hex: ascii_downcase | explode | reduce .[] as $c (0; . * 16 + (if $c >= 97 then $c - 87 else $c - 48 end));
        def month_of:
            [ ("jan|ian|янв"), ("feb|фев"), ("mar|мар"), ("apr|апр"), ("may|mai|мая|май"), ("jun|iun|июн"),
              ("jul|iul|июл"), ("aug|авг"), ("sep|сен"), ("oct|окт"), ("nov|noi|ноя"), ("dec|дек") ] as $m
            | . as $name | [ range(0; 12) as $i | select($name | test("(^|[^\\p{L}])(" + $m[$i] + ")"; "i")) | $i + 1 ] | first;
        def day_of: [ match("(?<![0-9])([0-3]?[0-9])(?![0-9])"; "g") | .captures[0].string | tonumber | select(. >= 1 and . <= 31) ] | first;
        [ .[] | . + { created: (.id[0:8] | hex), day: (.name | day_of), month: (.name | month_of) }
          | select(.day == $day and .month == $month and .created <= $ts + 86400 and .created >= $ts - 90 * 86400) ]
        | sort_by(.created) | last // empty | { id, name }' <<< "$LISTS")
    if [ -z "$LIST" ]; then
        print_error "No Trello list for $(TZ="$SHOW_TIMEZONE" date -r "$STREAMED_AT" "+%e %B" | sed 's/^ //') (the stream date of episode $EPISODE_NUMBER). Give the list name: -l \"<name>\""
        exit 1
    fi
fi

LIST_ID=$(jq -r '.id' <<< "$LIST")
print_message "Trello list: $(jq -r '.name' <<< "$LIST")"

CARDS=$(trello_get "lists/$LIST_ID/cards" --data-urlencode "fields=name,desc,pos" \
    --data-urlencode "attachments=true" --data-urlencode "attachment_fields=url,isUpload")

jq --argjson list "$LIST" --argjson exclude "$(print -rl -- "${TRELLO_LINK_EXCLUDE[@]}" | jq -R . | jq -s .)" '
    def excluded: . as $u | any($exclude[]; . as $p | $u | test($p; "i"));
    def clean: sub("[).,;:!?\\]>*_]+$"; "");
    def untrack: (split("#") | .[0]) as $u | ($u | split("?")) as $p
        | if ($p | length) < 2 then .
          else ($p[1] | split("&") | map(select(test("^(utm_[^=]*|fbclid|gclid|mc_[^=]*|_bhlid|ref_src)=") | not)) | join("&")) as $q
            | $p[0] + (if $q == "" then "" else "?" + $q end) end;
    { list: $list,
      cards: [ sort_by(.pos)[] | {
          name,
          links: ([ (.attachments[]? | select(.isUpload | not) | .url),
                    # more than 3 different links in the description: a pasted article, keep only its first link
                    (.desc | [ match("https?://[^\\s)\\]<>\"]+"; "g") | .string | clean ] | (reduce .[] as $l ([]; if index([$l]) then . else . + [$l] end))
                             | if length > 3 then .[0:1] else . end | .[]) ]
                  | map(untrack | select(excluded | not)) | reduce .[] as $l ([]; if index([$l]) then . else . + [$l] end)),
          desc: (.desc // "") } ] }' <<< "$CARDS" > "$OUTPUT"

print_success "Exported $(jq '.cards | length' "$OUTPUT") topics with $(jq '[.cards[].links[]] | length' "$OUTPUT") links to $EPISODE_DIR/$OUTPUT"
jq -r '.cards[] | "  \(.name): \(.links | length) link(s)"' "$OUTPUT"
