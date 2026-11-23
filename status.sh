#!/bin/zsh

# Where an episode stands in the pipeline, from the files alone: nothing is built, fetched or changed
# (no network, no YouTube quota). Prints one line per stage and the next step.
#
# Usage: ./status.sh <episode> [<episode>...]      (-e <episode> works too)

SCRIPTS_DIR="${0:A:h}"
cd "$SCRIPTS_DIR"

. ./messages.sh
. ./vars.sh
. ./transcript.sh
. ./r2.sh

set -uo pipefail

EPISODES=()
for arg in "$@"; do
    case $arg in
        -e ) ;;
        <-> ) EPISODES+=("$arg") ;;
        * ) echo "Usage: ./status.sh <episode> [<episode>...]" >&2; exit 1 ;;
    esac
done
(( ${#EPISODES} )) || { echo "Usage: ./status.sh <episode> [<episode>...]" >&2; exit 1; }

SOURCE_REPO="${COWSAY_SOURCE%/}"
SOURCE_REPO="${SOURCE_REPO:h}"

# line <stage> <state>
line() { printf "  %-10s %s\n" "$1" "$2"; }

status() {
    local ep="$1" dir="$COWSAY_DIR/$1" next="" cut="" method="" recipe_cut="" post="" name md5 logged live=false fix=""
    print "Episode $ep"
    if [ ! -d "$dir" ]; then
        line "files" "none yet"
        print "  next:      ./episode.sh -e $ep -u (first run: finds the recording and transcribes it)"
        return 0
    fi
    cd "$dir"

    if [ -s "stream-$ep.json" ]; then
        line "stream" "$(jq -r '"\(.title) (\(.date // "no date"))"' "stream-$ep.json")"
    else
        line "stream" "not looked up"
    fi

    if [ -f "raw$ep.mp3" ]; then
        line "raw" "raw$ep.mp3, $(printf %.0f "$(audio_duration "raw$ep.mp3")") s"
    else
        line "raw" "missing"
        next="${next:-./episode.sh -e $ep -u (first run: finds the recording and transcribes it)}"
    fi

    if [ -f "transcript-$ep.raw.json" ]; then
        line "transcript" "$(jq -r '"\(.provider // "elevenlabs"), \(.segments | length) segments"' "transcript-$ep.raw.json")"
    else
        line "transcript" "missing"
        next="${next:-./episode.sh -e $ep -u (transcription: the paid step)}"
    fi

    if [ -f "cut-$ep.txt" ]; then
        cut=$(< "cut-$ep.txt")
        [[ "$cut" == *:* ]] && cut=$(jq -rn --arg t "$cut" "$JQ_TIME"'$t | secs')
        method=$(cut -f1 "cut-$ep.info" 2>/dev/null || echo "?")
        line "cut" "$cut s ($method)"
    else
        line "cut" "not detected"
    fi

    if [ -f "cow$ep.mp3" ] && [ -f "cow$ep.mp3.build" ]; then
        recipe_cut=$(awk '$1 == "cut" { print $2 }' "cow$ep.mp3.build")
        if [ -n "$cut" ] && [ "$recipe_cut" != "$cut" ]; then
            line "mp3" "cow$ep.mp3 is STALE: built with cut $recipe_cut, the cut is now $cut"
            fix="./episode.sh -e $ep -u (rebuilds the mp3 with the new cut, uploads it as a new revision and patches the post)"
            next="${next:-$fix}"
        else
            line "mp3" "cow$ep.mp3 built ($(awk '$1 == "mode" { print $2 }' "cow$ep.mp3.build"), cut $recipe_cut)"
        fi
    elif [ -f "cow$ep.mp3" ]; then
        line "mp3" "cow$ep.mp3 (built before cow$ep.mp3.build existed: the next run rebuilds it once)"
    else
        line "mp3" "not built (the cut isn't approved yet)"
        next="${next:-review the cut and the topics: ./episode.sh -e $ep -u stops at them}"
    fi

    if [ -f "cow$ep.mp3" ]; then
        md5=$(md5 -q "cow$ep.mp3")
        name=$(r2_current_name "$ep")
        logged=$([ -f "$R2_UPLOAD_LOG" ] && awk -F'\t' -v ep="$ep" -v m="$md5" '$3 == ep && $5 == m && ($2 == "uploaded" || $2 == "found") { n = $4 } END { print n }' "$R2_UPLOAD_LOG")
        if [ -n "$logged" ]; then
            line "R2" "$logged (same audio as cow$ep.mp3)"
        elif [ -n "$name" ]; then
            line "R2" "$name, but cow$ep.mp3 differs from it (a rerun with -u uploads it as a new revision)"
            fix="${fix:-./episode.sh -e $ep -u (uploads cow$ep.mp3 as a new revision and patches the post)}"
        else
            line "R2" "not uploaded"
            next="${next:-./episode.sh -e $ep -u (uploads once the cut is approved)}"
        fi
    fi

    if [ -f "Records-$ep.csv" ]; then
        local rows extra=""
        rows=$(grep -cvE '^"[^"]*","(Intro|Outro|cut|moment)"' "Records-$ep.csv")
        [ -f "Records-$ep.cut" ] && [ -n "$cut" ] && (( $(< "Records-$ep.cut") != cut )) \
            && extra=", placed with cut $(< "Records-$ep.cut"): the next audio.sh run moves them"
        line "topics" "Records-$ep.csv, $rows topics$extra"
    else
        line "topics" "not placed"
        next="${next:-./episode.sh -e $ep -u (places the topics, then stops at the review)}"
    fi

    post=$(find_post "$ep")
    if [ -z "$post" ]; then
        line "post" "not written"
        next="${next:-approve the topics: the next run writes the post and stops at the site}"
    elif [ -n "$(git -C "$SOURCE_REPO" status --porcelain -- "$post")" ]; then
        line "post" "${post:t}, not committed (not live yet)"
        next="${next:-approve the site: the next run builds and pushes it}"
    elif [ "$(git -C "$SOURCE_REPO" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)" != 0 ]; then
        line "post" "${post:t}, committed but the site sources aren't pushed"
        next="${next:-./publish.sh $ep (pushes the site sources)}"
    else
        line "post" "${post:t}, committed and pushed"
        live=true
    fi

    if [ -f "youtube-offset-$ep.txt" ]; then
        line "YouTube" "offset $(< "youtube-offset-$ep.txt") s ($(cut -f1 "youtube-offset-$ep.info" 2>/dev/null || echo "?")); description not checked (./youtube-update.sh -e $ep -n does, about 50 quota units)"
    else
        line "YouTube" "offset not measured"
    fi

    [ "$live" = true ] && next="$fix"    # published: only a changed mp3 matters; other gaps predate the pipeline
    print "  next:      ${next:-nothing on the site side; check YouTube with ./youtube-update.sh -e $ep -n}"
    cd "$SCRIPTS_DIR"
}

for ep in "${EPISODES[@]}"; do
    status "$ep"
done
