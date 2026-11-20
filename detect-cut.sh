#!/bin/zsh

# Detect where the show actually starts in the raw recording (the intro crop point).
#
# Usage: ./detect-cut.sh -e <episode> [-v]
#
# Reads transcript-<ep>.raw.json (transcript of the uncut raw<ep>.mp3) and writes:
#   cut-<ep>.txt   crop offset in seconds, e.g. 171.115
#   cut-<ep>.info  how it was found: <method><TAB><evidence>
#
# Order: spoken marker (CUT_MARKERS) -> greeting found by the LLM -> CUT_DEFAULT.
# The chosen point is then moved back into the silence just before the first word.

SCRIPTS_DIR="${0:A:h}"
cd "$SCRIPTS_DIR"

. ./messages.sh
. ./logging.sh
. ./vars.sh
. ./utils.sh
. ./transcript.sh

set -euo pipefail

EPISODE_NUMBER=""

while getopts ":e:v" opt; do
    case ${opt} in
        e ) EPISODE_NUMBER=$OPTARG ;;
        v ) set -x ;;
        \? ) echo "Invalid option: -$OPTARG (-e <episode> [-v])" >&2; exit 1 ;;
        : ) echo "Option -$OPTARG requires an argument (-e <episode> [-v])" >&2; exit 1 ;;
    esac
done

if [ -z "$EPISODE_NUMBER" ]; then
    print_error "This script needs episode number in order to work"
    exit 1
fi

prepare_logging "detect-cut"
prepare_dir "$EPISODE_NUMBER"

TRANSCRIPT="transcript-$EPISODE_NUMBER.raw.json"
RAW="raw$EPISODE_NUMBER.mp3"
CUT_FILE="cut-$EPISODE_NUMBER.txt"
INFO_FILE="cut-$EPISODE_NUMBER.info"

for f in "$TRANSCRIPT" "$RAW"; do
    if [ ! -f "$f" ]; then
        print_error "$f not found in $EPISODE_DIR"
        exit 1
    fi
done

# 1. Spoken marker: the last marker word in the search window, then the first word after it
find_marker() {
    local markers
    markers=$(print -rl -- "${CUT_MARKERS[@]}" | jq -R 'ascii_downcase' | jq -s .)
    jq -r --argjson m "$markers" --argjson win "$CUT_SEARCH_WINDOW" '
        [ .segments[] | (.words // [ { text, start, end } ])[] | select(.start < $win) ] as $w
        | [ range(0; $w | length) as $i
            | select(($w[$i].text | ascii_downcase | gsub("[^\\p{L}]"; "")) as $t | any($m[]; . == $t))
            | $i ] as $hits
        | if ($hits | length) == 0 then empty else
            $hits[-1] as $h
            | ($w[$h + 1:] | map(select(.start >= $w[$h].end)) | first) as $next
            | if $next == null then empty
              else "\($next.start)\t\"\($w[$h].text)\" at \($w[$h].start)s, then: \([ $w[$h + 1:][:8][].text ] | join(" "))"
              end
          end
    ' "$TRANSCRIPT"
}

# 2. Greeting: ask the LLM where the show starts; snap its answer to the nearest segment start
find_greeting() {
    local lines prompt_file answer start quote confidence
    lines=$(jq -r --argjson win "$CUT_SEARCH_WINDOW" '
        .segments[] | select(.start < $win) | "[\(.start * 10 | round / 10)] \(.speaker // "?"): \(.text)"
    ' "$TRANSCRIPT")
    if [ -z "$lines" ]; then
        return 0
    fi

    prompt_file="cut-$EPISODE_NUMBER.prompt.txt"
    fill_template "$SCRIPTS_DIR/prompts/cut.md" \
        MARKERS "${(j:, :)CUT_MARKERS}" \
        WINDOW "$CUT_SEARCH_WINDOW" \
        TRANSCRIPT "$lines" > "$prompt_file"

    print_message "Asking Claude where the show starts..." >&2
    if ! answer=$(claude_json "$prompt_file" "$SCRIPTS_DIR/prompts/cut.schema.json"); then
        print_error "LLM greeting detection failed" >&2
        return 0
    fi
    rm -f "$prompt_file"

    if [ "$(jq -r '.found' <<< "$answer")" != "true" ]; then
        return 0
    fi

    start=$(jq -r '.start_seconds' <<< "$answer")
    quote=$(jq -r '.quote' <<< "$answer")
    confidence=$(jq -r '.confidence' <<< "$answer")
    start=$(jq -r --argjson t "$start" '[ .segments[].start ] | min_by(. - $t | fabs)' "$TRANSCRIPT")
    print -r -- "$start"$'\t'"$confidence confidence: \"$quote\""
}

# 3. Snap: move the point back into the silence right before the first word
snap_to_silence() {
    local t=$1 from len out rel s_start s_end cut
    (( from = t > 8 ? t - 8 : 0 ))
    (( len = t - from + 0.2 ))
    out=$(ffmpeg -nostdin -hide_banner -nostats -ss "$from" -t "$len" -i "$RAW" \
                 -af "silencedetect=noise=-35dB:d=0.3" -f null - 2>&1 || true)
    (( rel = t - from ))

    # the last silence that starts before the first word
    s_start=$(print -r -- "$out" | awk -v rel="$rel" '/silence_start:/ { v = $NF + 0; if (v < rel) s = v } END { if (s != "") print s }')
    if [ -n "$s_start" ]; then
        s_end=$(print -r -- "$out" | awk -v s="$s_start" '/silence_end:/ { v = $5 + 0; if (v > s && e == "") e = v } END { print (e == "" ? "" : e) }')
        [ -z "$s_end" ] && s_end=$rel
        (( s_end > rel )) && s_end=$rel
        (( cut = from + (s_end - CUT_PAD > s_start ? s_end - CUT_PAD : s_start) ))
    else
        (( cut = t - CUT_PAD ))
    fi
    (( cut < 0 )) && cut=0
    printf "%.3f" "$cut"
}

METHOD=""
RESULT=$(find_marker)
if [ -n "$RESULT" ]; then
    METHOD="marker"
else
    RESULT=$(find_greeting)
    [ -n "$RESULT" ] && METHOD="greeting"
fi

if [ -n "$METHOD" ]; then
    CANDIDATE=${RESULT%%$'\t'*}
    EVIDENCE=${RESULT#*$'\t'}
    CUT=$(snap_to_silence "$CANDIDATE")
else
    METHOD="default"
    EVIDENCE="nothing detected, using CUT_DEFAULT"
    CUT=$(printf "%.3f" "$CUT_DEFAULT")
    print_error "Could not detect the start of the show, falling back to $CUT_DEFAULT s"
fi

print -r -- "$CUT" > "$CUT_FILE"
print -r -- "$METHOD"$'\t'"$EVIDENCE" > "$INFO_FILE"

print_success "Intro cut at $(jq -rn "$JQ_TIME"" $CUT | hmsms") ($METHOD: $EVIDENCE) 🐮"
