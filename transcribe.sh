#!/bin/zsh

# Transcribe an audio file into the normalized transcript JSON (providers/README.md),
# using the provider set in vars.sh (TRANSCRIBE_PROVIDER).
#
# Usage: ./transcribe.sh -e <episode> -i <audio_in> -o <json_out> [-v]
#
# The result is cached: if <json_out> exists and was made from the same audio (md5),
# the paid call is skipped, even with -r upstream. Set TRANSCRIBE_FORCE=1 to force a new call.

SCRIPTS_DIR="${0:A:h}"
cd "$SCRIPTS_DIR"

. ./messages.sh
. ./logging.sh
. ./vars.sh
. ./secrets.sh
. ./utils.sh
. ./transcript.sh

set -euo pipefail

EPISODE_NUMBER=""
INPUT=""
OUTPUT=""

while getopts ":e:i:o:v" opt; do
    case ${opt} in
        e ) EPISODE_NUMBER=$OPTARG ;;
        i ) INPUT=$OPTARG ;;
        o ) OUTPUT=$OPTARG ;;
        v ) set -x ;;
        \? ) echo "Invalid option: -$OPTARG (-e <episode> -i <audio> -o <json> [-v])" >&2; exit 1 ;;
        : ) echo "Option -$OPTARG requires an argument (-e <episode> -i <audio> -o <json> [-v])" >&2; exit 1 ;;
    esac
done

if [ -z "$EPISODE_NUMBER" ] || [ -z "$INPUT" ] || [ -z "$OUTPUT" ]; then
    print_error "Usage: ./transcribe.sh -e <episode> -i <audio> -o <json> [-v]"
    exit 1
fi

prepare_logging "transcribe"
prepare_dir "$EPISODE_NUMBER"

if [ ! -f "$INPUT" ]; then
    print_error "Audio file $INPUT not found in $EPISODE_DIR"
    exit 1
fi

PROVIDER_FILE="$SCRIPTS_DIR/providers/$TRANSCRIBE_PROVIDER.sh"
if [ ! -f "$PROVIDER_FILE" ]; then
    print_error "Unknown transcription provider '$TRANSCRIBE_PROVIDER' (no $PROVIDER_FILE)"
    exit 1
fi
. "$PROVIDER_FILE"

# Cache check
HASH=$(md5 -q "$INPUT")
TRANSCRIBE_INPUT_HASH="$HASH"
HASH_FILE="$OUTPUT.md5"
if [ "${TRANSCRIBE_FORCE:-0}" != "1" ] && [ -f "$OUTPUT" ] && [ -f "$HASH_FILE" ] && [ "$(< "$HASH_FILE")" = "$HASH" ]; then
    print_message "Transcript $OUTPUT already exists for this audio, skipping the transcription"
    exit 0
fi

# Smaller upload: mono, 16 kHz is all speech recognition needs (timing is unchanged)
UPLOAD_FILE="transcribe-upload-$EPISODE_NUMBER.mp3"
print_message "Preparing a lightweight copy of the audio for transcription"
ffmpeg -nostdin -y -i "$INPUT" -vn -ac 1 -ar 16000 -b:a 48k "$UPLOAD_FILE" >> "$LOG" 2>&1

if ! provider_transcribe "$UPLOAD_FILE" "$OUTPUT"; then
    rm -f "$UPLOAD_FILE"
    print_error "Transcription failed (provider: $TRANSCRIBE_PROVIDER)"
    exit 1
fi
rm -f "$UPLOAD_FILE"

if ! validate_transcript "$OUTPUT"; then
    print_error "The $TRANSCRIBE_PROVIDER provider produced an invalid transcript: $OUTPUT"
    exit 1
fi

print -r -- "$HASH" > "$HASH_FILE"

print_success "Transcript ready: $OUTPUT ($(jq '.segments | length' "$OUTPUT") segments) 🐮"
