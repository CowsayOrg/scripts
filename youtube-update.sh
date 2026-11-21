#!/bin/zsh

# Update the episode's YouTube videos: description (with chapters and the link to the post),
# tags, category and language, the "Lives" playlist, and our transcript as captions.
#
# Usage: ./youtube-update.sh -e <episode> [-t "<title>"] [-n] [-r] [-v]
#   -t  rename the video (the vertical one gets the same title with " 📱"); without it the title is kept
#   -n  dry run: show what would change, change nothing (works without the YouTube login too)
#   -r  replace our caption track if it is already there
#
# Inputs (in $COWSAY_DIR/<ep>/):
#   stream-<ep>.json          the stream ids (stream.sh)
#   youtube-<ep>.txt          the description (template-yt.sh)
#   Records-<ep>.csv          topic titles, used as tags (topics.sh)
#   transcript-<ep>.raw.json  for the captions (audio.sh), shifted by youtube-offset-<ep>.txt (yt-align.sh);
#                             not uploaded when it was made from YouTube's own captions (providers/youtube.sh)
#   the post in $COWSAY_SOURCE, for the link
# The vertical 📱 stream gets the same description, tags, category and language, with a link to the
# main video on top. It gets no playlist and no captions (its timeline differs by a few seconds).
#
# Every change is shown as a diff and needs a y before anything is written.
# Quota: about 50 (description) + 51 (playlist) + 450 (captions) + 50 (vertical) of 10,000 a day.

SCRIPTS_DIR="${0:A:h}"
cd "$SCRIPTS_DIR"

. ./messages.sh
. ./logging.sh
. ./vars.sh
. ./utils.sh
. ./r2.sh
. ./yt-helpers.sh
. ./yt-api.sh

set -euo pipefail

EPISODE_NUMBER=""
DRY_RUN=false
REPLACE_CAPTIONS=false
NEW_TITLE=""

while getopts ":e:t:nrv" opt; do
    case ${opt} in
        e ) EPISODE_NUMBER=$OPTARG ;;
        t ) NEW_TITLE=$OPTARG ;;
        n ) DRY_RUN=true ;;
        r ) REPLACE_CAPTIONS=true ;;
        v ) set -x ;;
        * ) echo "Usage: $0 -e <episode> [-t \"<title>\"] [-n] [-r] [-v]" >&2; exit 1 ;;
    esac
done

if [ -z "$EPISODE_NUMBER" ]; then
    print_error "This script needs episode number in order to work"
    exit 1
fi

CONFIGURED=true
if ! yt_configured; then
    CONFIGURED=false
    if [ "$DRY_RUN" = false ]; then
        print_error "YouTube is not set up yet (see WORKFLOW.md, YouTube API), skipping the YouTube update. Run ./youtube-auth.sh once"
        exit 0
    fi
    print_message "YouTube is not set up yet: showing the proposed content only, without comparing it to the current one"
fi

prepare_logging "youtube-update"
prepare_dir "$EPISODE_NUMBER"

EP="$EPISODE_NUMBER"
STREAM_FILE="stream-$EP.json"
DESCRIPTION_FILE="youtube-$EP.txt"
RECORDS="Records-$EP.csv"
TRANSCRIPT="transcript-$EP.raw.json"
OFFSET_FILE="youtube-offset-$EP.txt"
SRT="youtube-captions-$EP.srt"

for f in "$STREAM_FILE" "$DESCRIPTION_FILE"; do
    if [ ! -s "$f" ]; then
        print_error "$f not found in $EPISODE_DIR (run stream.sh and template-yt.sh first)"
        exit 1
    fi
done

MAIN_ID=$(jq -r '.id' "$STREAM_FILE")
VERTICAL_ID=$(jq -r '.vertical_id // empty' "$STREAM_FILE")
if [ -z "$VERTICAL_ID" ]; then    # stream-<ep>.json from before the vertical id was saved
    VERTICAL_ID=$(streams_json | jq -r --argjson ep "$EP" '[ .[] | select(.vertical and .number == $ep) ] | first | .id // empty')
fi

##################################################################################
# Proposed content

# The description YouTube rejects "<" and ">", and allows 5000 bytes
sanitize() { sed -e 's/</‹/g' -e 's/>/›/g'; }

POST=$(find_post "$EP")
POST_LINE=""
if [ -n "$POST" ]; then
    D="${${POST:t}[1,10]}"
    POST_LINE="🎧 Episodul ca podcast: ${PUBLIC_ADDRESS%/}/${D[1,4]}/${D[6,7]}/${D[9,10]}/$EP.html"
else
    print_message "No post for episode $EP yet, the description goes without the link to the site"
fi

MAIN_DESCRIPTION=$( { [ -n "$POST_LINE" ] && printf '%s\n\n' "$POST_LINE"; cat "$DESCRIPTION_FILE"; } | sanitize)
VERTICAL_DESCRIPTION=$(printf '▶️ Versiunea orizontală: https://youtu.be/%s\n\n%s' "$MAIN_ID" "$MAIN_DESCRIPTION")

for d in MAIN_DESCRIPTION VERTICAL_DESCRIPTION; do
    if (( $(printf %s "${(P)d}" | wc -c) > 5000 )); then
        print_error "The description is longer than YouTube's 5000 bytes ($(printf %s "${(P)d}" | wc -c | tr -d ' ')). Shorten $DESCRIPTION_FILE"
        exit 1
    fi
done

# Tags: the base tags, then the topic titles without the "[Name] " prefix, while they fit in 500 characters
TOPIC_TITLES="[]"
if [ -f "$RECORDS" ]; then
    TOPIC_TITLES=$(csvformat -T "$RECORDS" 2>> "$LOG" | cut -f2 | jq -R . | jq -s '.')
fi
TAGS=$(jq -n --argjson base "$(print -rl -- "${YT_BASE_TAGS[@]}" | jq -R . | jq -s .)" --argjson topics "$TOPIC_TITLES" '
    def cost: length + (if test(" ") then 2 else 0 end) + 1;
    [ $base[], ($topics[] | select(. != "Intro" and . != "Outro" and . != "cut" and . != "moment")
                | sub("^\\[[^]]*\\]\\s*"; "") | gsub("[<>]"; "") | gsub("\\s*,\\s*"; " ") | select(length > 0 and length <= 100)) ]
    | reduce .[] as $t ([]; if (map(cost) | add // 0) + ($t | cost) <= 500 and (index([$t]) | not) then . + [$t] else . end)')

# snippet <video json> <description> [<title>]: the snippet to send (without a title, the one on YouTube is kept)
snippet() {
    jq --arg d "$2" --arg t "${3:-}" --argjson tags "$TAGS" --arg cat "$YT_CATEGORY_ID" --arg lang "$YT_LANGUAGE" '
        { title: (if $t == "" then .snippet.title else $t end), description: $d, tags: $tags, categoryId: $cat,
          defaultLanguage: $lang, defaultAudioLanguage: $lang }' <<< "$1"
}

# render <snippet json>: readable text for the diff
render() {
    jq -r '"Title: \(.title)\nCategory: \(.categoryId)\nLanguage: \(.defaultLanguage // "-") / audio \(.defaultAudioLanguage // "-")\nTags: \((.tags // []) | sort | join(", "))\n\n\(.description)"' <<< "$1"
}

# Captions: segments split into cues of at most ~6 s or ~80 characters, on the YouTube timeline
CAPTIONS=false
if [ -s "$TRANSCRIPT" ] && [ "$(jq -r '.provider // empty' "$TRANSCRIPT")" = youtube ]; then
    print_message "The transcript is YouTube's own automatic captions, no captions to upload"
elif [ -s "$TRANSCRIPT" ]; then
    YT_OFFSET=0
    if [ -s "$OFFSET_FILE" ]; then
        YT_OFFSET=$(< "$OFFSET_FILE")
    else
        print_message "No $OFFSET_FILE (yt-align.sh), assuming the video starts with the raw audio"
    fi
    jq -r --argjson off "$YT_OFFSET" '
        def ts: (. * 1000 | round) as $ms
            | "\($ms / 3600000 | floor | tostring | if length < 2 then "0" + . else . end):\($ms % 3600000 / 60000 | floor | tostring | if length < 2 then "0" + . else . end):\($ms % 60000 / 1000 | floor | tostring | if length < 2 then "0" + . else . end),\($ms % 1000 | tostring | ("00" + .)[-3:])";
        [ .segments[] | (if (.words // [] | length) > 0 then .words else [ { text: .text, start: .start, end: .end } ] end) as $w
          | reduce $w[] as $x ([];
              if length == 0 or ($x.start - .[-1].start > 6) or ((.[-1].text + " " + $x.text) | length > 80)
              then . + [ { start: $x.start, end: $x.end, text: $x.text } ]
              else .[-1].end = $x.end | .[-1].text += " " + $x.text end)
          | .[] ]
        | map(.start -= $off | .end -= $off | select(.end > 0) | .start = ([.start, 0] | max))
        | to_entries[] | "\(.key + 1)\n\(.value.start | ts) --> \(.value.end | ts)\n\(.value.text)\n"
    ' "$TRANSCRIPT" > "$SRT"
    CAPTIONS=true
    print_message "Captions: $SRT ($(grep -c -- '-->' "$SRT") cues)"
else
    print_message "No $TRANSCRIPT, no captions"
fi

##################################################################################
# Compare with YouTube and confirm

if [ "$CONFIGURED" = false ]; then
    EMPTY='{"snippet":{"title":"(current title)"}}'
    print_message "=== Main video $MAIN_ID ==="
    render "$(snippet "$EMPTY" "$MAIN_DESCRIPTION" "$NEW_TITLE")"
    if [ -n "$VERTICAL_ID" ]; then
        print_message "=== Vertical video $VERTICAL_ID: same, with this first line ==="
        print -r -- "${VERTICAL_DESCRIPTION%%$'\n'*}"
    fi
    print_message "Playlist: Lives ($YT_LIVES_PLAYLIST)"
    exit 0
fi

MAIN_VIDEO=$(yt_video "$MAIN_ID")
if [ -z "$MAIN_VIDEO" ]; then
    print_error "Video $MAIN_ID not found, or this channel can't edit it"
    exit 1
fi
MAIN_NEW=$(snippet "$MAIN_VIDEO" "$MAIN_DESCRIPTION" "$NEW_TITLE")
MAIN_CHANGED=false
print_message "=== Main video https://youtu.be/$MAIN_ID ==="
if diff -u --label "now on YouTube" --label "proposed" <(render "$(jq '.snippet' <<< "$MAIN_VIDEO")") <(render "$MAIN_NEW"); then
    print_message "Already up to date"
else
    MAIN_CHANGED=true
fi

VERTICAL_CHANGED=false
if [ -n "$VERTICAL_ID" ]; then
    VERTICAL_VIDEO=$(yt_video "$VERTICAL_ID")
    if [ -n "$VERTICAL_VIDEO" ]; then
        VERTICAL_NEW=$(snippet "$VERTICAL_VIDEO" "$VERTICAL_DESCRIPTION" "${NEW_TITLE:+$NEW_TITLE 📱}")
        print_message "=== Vertical video https://youtu.be/$VERTICAL_ID ==="
        if diff -u --label "now on YouTube" --label "proposed" <(render "$(jq '.snippet' <<< "$VERTICAL_VIDEO")") <(render "$VERTICAL_NEW"); then
            print_message "Already up to date"
        else
            VERTICAL_CHANGED=true
        fi
    fi
fi

ADD_TO_PLAYLIST=false
PLAYLIST_STATUS=0
yt_in_playlist "$YT_LIVES_PLAYLIST" "$MAIN_ID" || PLAYLIST_STATUS=$?
case $PLAYLIST_STATUS in
    0 ) print_message "Already in the Lives playlist" ;;
    1 ) ADD_TO_PLAYLIST=true; print_message "Will add it to the Lives playlist" ;;
    * ) print_error "Could not check the Lives playlist"; exit 1 ;;
esac

CAPTION_ACTION=""
if [ "$CAPTIONS" = true ]; then
    CAPTION_ID=$(yt_caption_id "$MAIN_ID" "$YT_CAPTION_NAME")
    if [ -z "$CAPTION_ID" ]; then
        CAPTION_ACTION=insert
        print_message "Will upload the captions \"$YT_CAPTION_NAME\" ($YT_LANGUAGE)"
    elif [ "$REPLACE_CAPTIONS" = true ]; then
        CAPTION_ACTION=replace
        print_message "Will replace the captions \"$YT_CAPTION_NAME\""
    else
        print_message "Captions \"$YT_CAPTION_NAME\" already there (use -r to replace them)"
    fi
fi

if [ "$MAIN_CHANGED$VERTICAL_CHANGED$ADD_TO_PLAYLIST" = falsefalsefalse ] && [ -z "$CAPTION_ACTION" ]; then
    print_success "YouTube is up to date 🐮"
    exit 0
fi
if [ "$DRY_RUN" = true ]; then
    print_message "Dry run, nothing changed"
    exit 0
fi

print_message "Apply these changes on YouTube? y/[n]"
read ANSWER
if [ "$ANSWER" != "y" ]; then
    print_error "Nothing changed on YouTube"
    exit 0
fi

##################################################################################
# Apply

if [ "$MAIN_CHANGED" = true ]; then
    yt_api_json PUT "$YT_API/videos?part=snippet" "$(jq -n --arg id "$MAIN_ID" --argjson s "$MAIN_NEW" '{ id: $id, snippet: $s }')" > /dev/null
    print_success "Main video updated"
    if [ -n "$NEW_TITLE" ]; then    # keep the cached stream title in step (template-md.sh, audio.sh read it)
        jq --arg t "$NEW_TITLE" '.title = $t' "$STREAM_FILE" > "$STREAM_FILE.tmp" && mv "$STREAM_FILE.tmp" "$STREAM_FILE"
    fi
fi
if [ "$VERTICAL_CHANGED" = true ]; then
    yt_api_json PUT "$YT_API/videos?part=snippet" "$(jq -n --arg id "$VERTICAL_ID" --argjson s "$VERTICAL_NEW" '{ id: $id, snippet: $s }')" > /dev/null
    print_success "Vertical video updated"
fi
if [ "$ADD_TO_PLAYLIST" = true ]; then
    yt_add_to_playlist "$YT_LIVES_PLAYLIST" "$MAIN_ID"
    print_success "Added to the Lives playlist"
fi
if [ "$CAPTION_ACTION" = insert ]; then
    yt_upload_caption "$MAIN_ID" "$SRT"
    print_success "Captions uploaded"
elif [ "$CAPTION_ACTION" = replace ]; then
    yt_upload_caption "$MAIN_ID" "$SRT" "$CAPTION_ID"
    print_success "Captions replaced"
fi

print_success "YouTube updated: https://youtu.be/$MAIN_ID 🐮"
