#!/bin/zsh

. ./messages.sh
. ./logging.sh
. ./vars.sh
. ./utils.sh

prepare_raw() {
    if [ "$REWRITE" = true ]; then
        rm "$RAW"
    fi

    if [ -f "$RAW" ]; then
        print_message "RAW file already exists"
        return 0
    fi

    if [ -n "$FILE_SOURCE" ]; then
        cp "$FILE_SOURCE" "$RAW"
    elif [ -n "$YOUTUBE_URL" ]; then
        youtube_download
    else
        print_error "Script requires either youtube source URL or local file path (-y/-l)"
        exit 1
    fi
}

check_ffmpeg() {
    if ! command -v ffmpeg > "$LOG" 2>&1
    then
        check-brew
        print_message "You miss FFMPEG. Installing it..."
        brew install ffmpeg
    fi
}

check-brew() {
    if ! command -v brew > "$LOG" 2>&1; then
        print_error "You miss Homebrew. Please install it before contining"
        exit 1
    fi
}

youtube_download() {
    if ! command -v yt-dlp > "$LOG" 2>&1
    then
        check-brew
        print_message "You miss Youtube-dl. Installing it..."
        brew install yt-dlp
    fi

    print_message "Downloading audio from the video: "$YOUTUBE_URL""
    yt-dlp -x --audio-format mp3 $YOUTUBE_URL -o "$RAW" > "$LOG" 2>&1
}

crop() {
    if [ "$TESTRUN" = true ]; then
        print_message "No cropping on test run"
        CROPPED="$RAW"
        return 0
    fi

    if [ "$REWRITE" = true ]; then
        rm "$CROPPED"
    fi

    if [ -f "$CROPPED" ]; then
        print_message "CROPPED file already exists"
        return 0
    fi

    check_ffmpeg
    print_message "Cutting down intro from the file"
    ffmpeg -i "$RAW" -ss "$CUT" "$CROPPED" > "$LOG" 2>&1
}

add_compression() {
    if [ "$REWRITE" = true ]; then
        rm "$COMPRESSED"
    fi

    if [ -f "$COMPRESSED" ]; then
        print_message "COMPRESSED file already exists"
        return 0
    fi

    check_ffmpeg
    print_message "Adding some compression effect."
    ffmpeg -i "$CROPPED" -af "acompressor" "$COMPRESSED" > "$LOG" 2>&1
}

add_metadata() {
    if [ "$REWRITE" = true ]; then
        rm "$FINAL"
    fi

    if [ -f "$FINAL" ]; then
        print_message "FINAL file already exists"
        return 0
    fi

    check_ffmpeg
    print_message "Adding metadata to the mp3 file"

    TITLE="Live $EPISODE_NUMBER"
    ARTIST="Cowsay Show"
    YEAR=$(date +\"%Y\")
    GENRE="Podcast"

    ffmpeg -i "$COMPRESSED" -i "$COVER" -map 0 -map 1 -metadata title="$TITLE" -metadata artist="$ARTIST" -metadata genre="$GENRE" -metadata year="$YEAR" -c copy $FINAL > "$LOG" 2>&1
}

clean() {
    if [ "$TESTRUN" = true ]; then
        print_message "No cleaning on test run"
        return 0
    fi

    print_message "Cleaning up the environment"
    rm "$CROPPED" > "$LOG" 2>&1
    rm "$COMPRESSED" > "$LOG" 2>&1
}

azure_upload() {
    print_message "Uploading the file to the Azure"

    if ! command -v azcopy > "$LOG" 2>&1
    then
        check-brew
        print_message "You miss Azcopy. Installing it..."
        brew install azcopy
    fi

    LOGIN="$(azcopy login status)"

    if [[ "$LOGIN" == *"not logged in"* ]]; then
        print_error "You are not logged in to azcopy..."
        exit 1
    fi

    URL=""$AZURE_DIR""$FINAL""

    azcopy copy "$FINAL" "$URL" > "$LOG" 2>&1
}

##################################################################################

print_message "Preparing to execute the script"

set -euo pipefail
# set -x

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

# Read Arguments

while getopts ":e:y:l:utr" opt; do
    case ${opt} in
        e )
            EPISODE_NUMBER=$OPTARG
            ;;
        y )
            YOUTUBE_URL=$OPTARG
            ;;
        l )
            FILE_SOURCE=$OPTARG
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
        \? )
            echo "Invalid option: -$OPTARG (-e -y/-l [-u])" >&2
            exit 1
            ;;
        : )
            echo "Option -$OPTARG requires an argument (-e -y/-l [-u])" >&2
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

prepare_dir "$EPISODE_NUMBER"

CUT=$(cat "cut-$EPISODE_NUMBER.txt")

prepare_raw
crop

# Check if the crop is correct

qlmanage -p "$CROPPED"
print_message "Do you want to proceed with this variant? y/[n]"
read ANSWER

if [ -n "$ANSWER" ] && [ $ANSWER = "y" ]; then
    print_message "Continuing..."
else
    print_error "Not using this variant. Please run the script again"
    clean
    exit 0
fi

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

azure_upload
print_success "Audio file is successfully prepared and uploaded 🐮."
clean