#!/bin/zsh

# ElevenLabs Scribe speech-to-text adapter.
# Sourced by transcribe.sh. Needs ELEVENLABS_API_KEY (secrets.sh), ELEVENLABS_MODEL and TRANSCRIBE_LANGUAGE (vars.sh).
# API: https://elevenlabs.io/docs/api-reference/speech-to-text/convert

# provider_transcribe <audio_in> <normalized_json_out>
# The provider's own response is kept next to the output as <out>.provider.json.
provider_transcribe() {
    local in="$1" out="$2" response="${2:r}.provider.json"

    if [ -z "${ELEVENLABS_API_KEY:-}" ]; then
        print_error "ELEVENLABS_API_KEY is not set. Add it to secrets.sh"
        return 1
    fi

    # Reuse a paid response for the same audio (TRANSCRIBE_INPUT_HASH is set by transcribe.sh)
    if [ -f "$response" ] && [ -f "$response.md5" ] && [ "$(< "$response.md5")" = "${TRANSCRIBE_INPUT_HASH:-none}" ] \
       && [ "${TRANSCRIBE_FORCE:-0}" != "1" ]; then
        print_message "Reusing the saved ElevenLabs response $response"
    else
        _elevenlabs_request "$in" "$response" || return 1
    fi

    _elevenlabs_normalize "$response" > "$out"
}

_elevenlabs_request() {
    local in="$1" response="$2" http_code

    print_message "Sending audio to ElevenLabs ($ELEVENLABS_MODEL, $TRANSCRIBE_LANGUAGE)... this takes a few minutes"
    http_code=$(curl -sS -o "$response.part" -w '%{http_code}' -X POST "https://api.elevenlabs.io/v1/speech-to-text" \
        -H "xi-api-key: $ELEVENLABS_API_KEY" \
        -F "file=@$in" \
        --form-string "model_id=$ELEVENLABS_MODEL" \
        --form-string "language_code=$TRANSCRIBE_LANGUAGE" \
        --form-string "timestamps_granularity=word" \
        --form-string "diarize=true" \
        --form-string "tag_audio_events=false")

    if [ "$http_code" != "200" ]; then
        print_error "ElevenLabs returned HTTP $http_code:"
        cat "$response.part" >&2
        rm -f "$response.part"
        return 1
    fi
    mv "$response.part" "$response"
    print -r -- "${TRANSCRIBE_INPUT_HASH:-none}" > "$response.md5"
}

# words[] -> segments: split on speaker change, a pause over 1.5 s, or sentence end
_elevenlabs_normalize() {
    jq '
        [ .words[] | select(.type == "word" and .start != null and .end != null) ] as $w
        | {
            provider: "elevenlabs",
            language: .language_code,
            segments: (
                reduce $w[] as $x ([];
                    if length > 0
                       and $x.speaker_id == .[-1].speaker
                       and ($x.start - .[-1].end) <= 1.5
                       and ((.[-1].words[-1].text | test("[.!?…]$")) | not)
                    then .[-1].end = $x.end | .[-1].words += [ { text: $x.text, start: $x.start, end: $x.end } ]
                    else . + [ { start: $x.start, end: $x.end, speaker: $x.speaker_id,
                                 words: [ { text: $x.text, start: $x.start, end: $x.end } ] } ]
                    end)
                | map(.text = (.words | map(.text) | join(" ")))
            )
        }
    ' "$1"
}
