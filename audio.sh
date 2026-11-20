#!/bin/zsh

# Prepare the episode audio: get the raw recording, transcribe it, detect the intro cut,
# crop, compress, tag, and optionally upload to Cloudflare R2.
#
# Usage: ./audio.sh -e <episode> (-l <mp3> | -y <youtube_url>) [-u] [-t] [-r] [-v]

SCRIPTS_DIR="${0:A:h}"

. ./messages.sh
. ./logging.sh
. ./vars.sh
. ./utils.sh
. ./transcript.sh
. ./r2.sh

prepare_raw() {
    if [ -f "$RAW" ] && [ "$REWRITE" = false ]; then
        print_message "RAW file already exists"
        return 0
    fi
    if [ -n "$FILE_SOURCE" ] && [ "$FILE_SOURCE" = "${RAW:A}" ]; then
        print_message "Using the existing $RAW"
        return 0
    fi
    rm -f "$RAW"

    if [ -n "$FILE_SOURCE" ] && [[ "${(L)FILE_SOURCE:e}" == mp3 ]]; then
        cp "$FILE_SOURCE" "$RAW"
    elif [ -n "$FILE_SOURCE" ]; then
        # video or another audio format: keep only the audio, as mp3
        check_ffmpeg
        print_message "Extracting the audio from ${FILE_SOURCE:t}"
        ffmpeg -nostdin -y -i "$FILE_SOURCE" -vn -c:a libmp3lame -q:a 2 "$RAW" >> "$LOG" 2>&1
    elif [ -n "$YOUTUBE_URL" ]; then
        youtube_download
    else
        print_error "Script requires either youtube source URL or local file path (-y/-l)"
        exit 1
    fi
}

check_ffmpeg() {
    if ! command -v ffmpeg >> "$LOG" 2>&1
    then
        print_error "You miss FFmpeg. Please install all the dependencies from requirements.txt"
        exit 1
    fi
}

youtube_download() {
    if ! command -v yt-dlp >> "$LOG" 2>&1
    then
        print_error "You miss Youtube-dl. Please install all the dependencies from requirements.txt"
        exit 1
    fi

    print_message "Downloading audio from the video: $YOUTUBE_URL"
    yt-dlp -x --audio-format mp3 "$YOUTUBE_URL" -o "$RAW" >> "$LOG" 2>&1
}

# needs_build <target> <source>: true if target is missing, older than source, or -r was given
needs_build() {
    [ "$REWRITE" = true ] || [ ! -f "$1" ] || [[ "$2" -nt "$1" ]]
}

transcribe_raw() {
    "$SCRIPTS_DIR/transcribe.sh" -e "$EPISODE_NUMBER" -i "$RAW" -o "$RAW_TRANSCRIPT" ${VERBOSE_FLAG[@]}
}

detect_cut() {
    if needs_build "$CUT_FILE" "$RAW_TRANSCRIPT"; then
        "$SCRIPTS_DIR/detect-cut.sh" -e "$EPISODE_NUMBER" ${VERBOSE_FLAG[@]}
    else
        print_message "Using the existing cut point from $CUT_FILE"
    fi
}

# read_cut: crop offset in seconds (accepts the old HH:MM:SS format too)
read_cut() {
    local value
    value=$(< "$CUT_FILE")
    if [[ "$value" == *:* ]]; then
        jq -rn --arg t "$value" "$JQ_TIME"'$t | secs'
    else
        print -r -- "$value"
    fi
}

crop() {
    CUT=$(read_cut)

    if ! needs_build "$CROPPED" "$CUT_FILE"; then
        print_message "CROPPED file already exists"
        return 0
    fi
    rm -f "$CROPPED"

    check_ffmpeg
    if [ "$TESTRUN" = true ]; then
        print_message "Test run: fast crop at $CUT s (stream copy)"
        ffmpeg -nostdin -y -ss "$CUT" -i "$RAW" -c copy "$CROPPED" >> "$LOG" 2>&1
    else
        print_message "Cutting the intro at $CUT s"
        ffmpeg -nostdin -y -i "$RAW" -ss "$CUT" "$CROPPED" >> "$LOG" 2>&1
    fi
}

# Shift the raw transcript onto the podcast timeline (the crop is a plain offset)
shift_to_podcast_timeline() {
    shift_transcript "$RAW_TRANSCRIPT" "$TRANSCRIPT" "$CUT"
    transcript_to_text "$TRANSCRIPT" "$TRANSCRIPT_TXT"
}

preview() {
    local method evidence answer
    while true; do
        method=$(cut -f1 "$CUT_INFO" 2>/dev/null || echo "existing")
        evidence=$(cut -f2- "$CUT_INFO" 2>/dev/null || echo "")
        print_message "Intro cut at $(jq -rn "$JQ_TIME"" $CUT | hmsms") ($method) $evidence"
        print_message "Opening the cropped file. Close the preview, then answer."
        qlmanage -p "$CROPPED" >> "$LOG" 2>&1
        print_message "Do you want to proceed with this variant? y / [n] / <seconds> to set the cut manually"
        read answer

        if [ "$answer" = "y" ]; then
            print_message "Continuing..."
            return 0
        elif [[ "$answer" =~ '^[0-9]+([.][0-9]+)?$' ]]; then
            print -r -- "$answer" > "$CUT_FILE"
            print -r -- "manual"$'\t'"set at the preview" > "$CUT_INFO"
            crop
            shift_to_podcast_timeline
        else
            print_error "Not using this variant. Please run the script again"
            clean
            exit 0
        fi
    done
}

add_compression() {
    if ! needs_build "$COMPRESSED" "$CROPPED"; then
        print_message "COMPRESSED file already exists"
        return 0
    fi
    rm -f "$COMPRESSED"

    check_ffmpeg
    print_message "Adding some compression effect."
    ffmpeg -nostdin -y -i "$CROPPED" -af "acompressor" "$COMPRESSED" >> "$LOG" 2>&1
}

add_metadata() {
    if ! needs_build "$FINAL" "$COMPRESSED"; then
        print_message "FINAL file already exists"
        return 0
    fi
    rm -f "$FINAL"

    check_ffmpeg
    print_message "Adding metadata to the mp3 file"

    TITLE="Live $EPISODE_NUMBER"
    if [ -s "stream-$EPISODE_NUMBER.json" ]; then
        TITLE=$(jq -r '.title' "stream-$EPISODE_NUMBER.json")
    fi
    ARTIST="Cowsay Show"
    YEAR=$(date +%Y)
    GENRE="Podcast"

    ffmpeg -nostdin -y -i "$COMPRESSED" -i "$COVER" -map 0 -map 1 -metadata title="$TITLE" -metadata artist="$ARTIST" -metadata genre="$GENRE" -metadata year="$YEAR" -c copy "$FINAL" >> "$LOG" 2>&1
}

clean() {
    if [ "$TESTRUN" = true ]; then
        print_message "No cleaning on test run"
        return 0
    fi

    print_message "Cleaning up the environment"
    rm -f "$CROPPED" "$COMPRESSED"
}

r2_upload() {
    local url code

    if ! command -v rclone >> "$LOG" 2>&1; then
        print_error "You miss rclone. Please install all the dependencies from requirements.txt"
        exit 1
    fi
    if ! rclone listremotes | grep -qx "$R2_REMOTE:"; then
        print_error "rclone remote '$R2_REMOTE' is not configured. Run: rclone config"
        exit 1
    fi

    local md5 choice name post
    md5=$(md5 -q "$FINAL")
    choice=$(r2_choose_name "$EPISODE_NUMBER" "$md5")
    name="${choice#* }"

    if [ "${choice%% *}" = "same" ]; then
        print_message "This audio is already uploaded as $name, skipping the upload"
    else
        if [ "$name" != "$FINAL" ]; then
            print_message "An older $FINAL is already in the locked bucket, uploading this revision as $name"
        fi
        print_message "Uploading $FINAL to R2 ($R2_REMOTE:$R2_BUCKET/$name)"
        # The R2 token can write objects but not list buckets, so skip the bucket and destination checks
        rclone copyto "$FINAL" "$R2_REMOTE:$R2_BUCKET/$name" \
            --s3-no-check-bucket --no-check-dest --s3-no-head >> "$LOG" 2>&1

        url="$PUBLIC_AUDIO_URL/$name"
        code=$(curl -s -o /dev/null -I -w '%{http_code}' "$url")
        if [ "$code" != "200" ]; then
            print_error "Upload finished but $url answers HTTP $code"
            exit 1
        fi
        r2_log uploaded "$EPISODE_NUMBER" "$name" "$md5"
        print_success "Available at $url (logged in $R2_UPLOAD_LOG)"
    fi

    # A fix of an already published episode: point its post to the new file
    post=$(find_post "$EPISODE_NUMBER")
    if [ -n "$post" ] && ! grep -qx "  mp3: $name" "$post"; then
        patch_post_audio "$post" "$name" "$(stat -f%z "$FINAL")" "$(post_duration "$FINAL")"
        print_success "Updated ${post:t} to $name, run publish.sh to deploy it"
    fi
}

##################################################################################

print_message "Preparing to execute the script"

set -euo pipefail

# Prepare the logs
prepare_logging "audio"

# Check on OS

OS="$(uname -s)"

if [ $OS != "Darwin" ]; then
    print_error "This script is meant to be running on macOS"
    exit 1
fi

# Init and check arguments

# Default values
EPISODE_NUMBER=""
FILE_SOURCE=""
YOUTUBE_URL=""
UPLOAD=false
TESTRUN=false
REWRITE=false
VERBOSE_FLAG=()

# Read Arguments

while getopts ":e:y:l:utrv" opt; do
    case ${opt} in
        e )
            EPISODE_NUMBER=$OPTARG
            ;;
        y )
            YOUTUBE_URL=$OPTARG
            ;;
        l )
            FILE_SOURCE=${OPTARG:A}
            ;;
        u )
            UPLOAD=true
            ;;
        t )
            TESTRUN=true
            ;;
        r )
            REWRITE=true
            ;;
        v )
            VERBOSE_FLAG=(-v)
            set -x
            ;;
        \? )
            echo "Invalid option: -$OPTARG (-e -y/-l [-u] [-t] [-r] [-v])" >&2
            exit 1
            ;;
        : )
            echo "Option -$OPTARG requires an argument (-e -y/-l [-u] [-t] [-r] [-v])" >&2
            exit 1
            ;;
    esac
done

if [ -z "$EPISODE_NUMBER" ]; then
    print_error "This script needs episode number in order to work"
    exit 1
fi

# Files
RAW="raw$EPISODE_NUMBER.mp3"
CROPPED="cropped$EPISODE_NUMBER.mp3"
COMPRESSED="compressed$EPISODE_NUMBER.mp3"
FINAL="cow$EPISODE_NUMBER.mp3"
RAW_TRANSCRIPT="transcript-$EPISODE_NUMBER.raw.json"
TRANSCRIPT="transcript-$EPISODE_NUMBER.json"
TRANSCRIPT_TXT="transcript-$EPISODE_NUMBER.txt"
CUT_FILE="cut-$EPISODE_NUMBER.txt"
CUT_INFO="cut-$EPISODE_NUMBER.info"

prepare_dir "$EPISODE_NUMBER"

prepare_raw
transcribe_raw
detect_cut
crop
shift_to_podcast_timeline
preview

if [ "$TESTRUN" = false ]; then
    add_compression
else
    print_message "No compression on test run"
    COMPRESSED="$CROPPED"
fi

add_metadata

if [ "$UPLOAD" = "false" ]; then
    print_success "The script has finished successfuly without file upload 🐮."
    clean
    exit 0
fi

r2_upload
print_success "Audio file is successfully prepared and uploaded 🐮."
clean
