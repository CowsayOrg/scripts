#!/bin/zsh

# YouTube automatic captions as the transcript (free, no audio upload).
#
# The captions are on the YouTube video's timeline, so they only fit audio that is YouTube's own
# download of the stream (or starts exactly like it): provider_transcribe refuses audio whose
# duration differs from the stream's by more than AUDIO_DURATION_TOLERANCE. Quality is lower than
# ElevenLabs (no punctuation in places, no speakers), but good enough to place topics and cut the intro.
#
# Needs stream-<ep>.json (stream.sh) in the episode directory, and yt-dlp.
# Use it with TRANSCRIBE_PROVIDER=youtube ./episode.sh ... or set it in vars.sh.

# youtube_captions_transcript <stream url> <json out>: download the auto captions, write the normalized JSON
youtube_captions_transcript() {
    local url="$1" out="$2" tmp subs
    tmp=$(mktemp -d)
    yt-dlp --skip-download --write-auto-subs --sub-langs "$YT_LANGUAGE-orig,$YT_LANGUAGE" --sub-format json3 \
        -o "$tmp/subs.%(ext)s" "$url" >> "${LOG:-/dev/null}" 2>&1 || true
    subs=("$tmp"/subs.$YT_LANGUAGE-orig.json3(N) "$tmp"/subs.*.json3(N))
    if (( ${#subs} == 0 )); then
        rm -rf "$tmp"
        print_error "No automatic captions on YouTube for $url (they appear a while after the stream)"
        return 1
    fi
    # Each caption event is one short line; its words carry offsets from the event start
    jq --arg lang "$YT_LANGUAGE" '
        { provider: "youtube", language: $lang,
          segments: ([ .events[] | select(.segs) | .tStartMs as $s | (.dDurationMs // 0) as $d
              | [ .segs[] | select(.utf8 | test("\\S")) | { text: (.utf8 | gsub("^\\s+|\\s+$"; "")), start: (($s + (.tOffsetMs // 0)) / 1000) } ] as $w
              | select($w | length > 0)
              | { start: ($s / 1000), end: (($s + $d) / 1000), text: ($w | map(.text) | join(" ")),
                  words: [ range(0; $w | length) as $i | $w[$i] + { end: (if $i + 1 < ($w | length) then $w[$i + 1].start else ($s + $d) / 1000 end) } ] } ]
          | sort_by(.start)
          # events overlap (a line stays on screen while the next one appears): end each at the next start
          | . as $a | [ range(0; length) as $i | $a[$i] | if $i + 1 < ($a | length) and .end > $a[$i + 1].start then .end = $a[$i + 1].start else . end ]) }
    ' "${subs[1]}" > "$out"
    rm -rf "$tmp"
}

provider_transcribe() {
    local in="$1" out="$2" stream="stream-$EPISODE_NUMBER.json" audio_dur stream_dur
    if [ ! -s "$stream" ]; then
        print_error "The youtube provider needs $stream (run stream.sh first)"
        return 1
    fi
    audio_dur=$(audio_duration "$in")
    stream_dur=$(jq -r '.duration // empty' "$stream")
    if [ -n "$stream_dur" ] && (( audio_dur - stream_dur > AUDIO_DURATION_TOLERANCE || stream_dur - audio_dur > AUDIO_DURATION_TOLERANCE )); then
        print_error "The audio ($(printf %.0f "$audio_dur") s) isn't the YouTube stream ($stream_dur s): its captions wouldn't line up. Use another provider"
        return 1
    fi
    print_message "Using YouTube's automatic captions as the transcript (free)"
    youtube_captions_transcript "$(jq -r '.url' "$stream")" "$out"
}
