#!/bin/zsh

# Helpers for the normalized transcript JSON (see providers/README.md):
# { "language": "ro", "segments": [ { "start", "end", "text", "speaker"?, "words"?: [ { "text", "start", "end" } ] } ] }

# jq helpers for time formatting, prepended to jq programs
JQ_TIME='
def pad(n): tostring | (n - length) as $k | (if $k > 0 then ("0" * $k) else "" end) + .;
def hms: floor as $s | "\(($s / 3600 | floor) | pad(2)):\((($s % 3600) / 60 | floor) | pad(2)):\(($s % 60) | pad(2))";
def hmsms: (. * 1000 | round) as $m | (($m / 1000 | floor) | hms) + "." + (($m % 1000) | pad(3));
def secs: split(":") | map(tonumber) | .[0] * 3600 + .[1] * 60 + .[2];
'

# validate_transcript <file>: non-empty segments with numeric start/end and text
validate_transcript() {
    jq -e '(.segments | type == "array" and length > 0)
           and all(.segments[]; (.start | type == "number") and (.end | type == "number") and (.text | type == "string"))' \
        "$1" > /dev/null
}

# shift_transcript <in> <out> <offset_seconds>: move everything back by the crop offset, drop what was cut
shift_transcript() {
    jq --argjson off "$3" '
        def shift: .start = ([.start - $off, 0] | max) | .end = (.end - $off);
        .offset = $off
        | .segments = [ .segments[] | select(.end > $off) | shift
                        | if .words then .words = [ .words[] | select(.end > $off) | shift ] else . end ]
    ' "$1" > "$2"
}

# transcript_to_text <in> <out>: compact "[HH:MM:SS] text" lines, one per TRANSCRIPT_BLOCK seconds, for the LLM
transcript_to_text() {
    jq -r --argjson block "${TRANSCRIPT_BLOCK:-10}" "$JQ_TIME"'
        reduce .segments[] as $s ([];
            if length == 0 or ($s.start - .[-1].start) >= $block
            then . + [ { start: $s.start, text: $s.text } ]
            else .[-1].text += " " + $s.text end)
        | .[] | "[\(.start | hms)] \(.text)"
    ' "$1" > "$2"
}

# audio_duration <file>: duration in seconds
audio_duration() {
    ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$1"
}

# claude_json <prompt_file> <schema_file>: run Claude Code headless, print the structured output JSON
claude_json() {
    local response
    response=$(claude -p --model "$LLM_MODEL" --tools "" --output-format json \
                      --json-schema "$(cat "$2")" < "$1")
    if ! jq -e '.is_error == false and .structured_output != null' > /dev/null <<< "$response"; then
        print_error "Claude call failed:"
        jq -r '.result // .' <<< "$response" >&2
        return 1
    fi
    jq '.structured_output' <<< "$response"
}

# fill_template <template> NAME value [NAME value ...]: replace @@NAME@@ placeholders
fill_template() {
    local text
    text=$(< "$1")
    shift
    while [ $# -gt 1 ]; do
        text=${text//@@$1@@/$2}
        shift 2
    done
    print -r -- "$text"
}
