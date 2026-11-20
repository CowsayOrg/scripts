#!/bin/zsh

# Paths
COWSAY_DIR="/Users/user/cowsay-show-files"
COVER=""$COWSAY_DIR"/cow-logo.png"
COWSAY_SOURCE="/Users/user/Code/Cowsay/cowsay-source/_posts/"
SITE_DIR="/Users/user/Code/Cowsay/cowsay-source/_site"
SITE_REPO="git@github.com:CowsayOrg/CowsayOrg.github.io.git"
GITHUB_CERT_PATH="/Users/user/.ssh/github"
LOCAL_ADDRESS="http://127.0.0.1:4000"
PUBLIC_ADDRESS="https://cowsay.show/"

# Audio hosting: Cloudflare R2, uploaded with rclone (credentials live in the rclone config)
R2_REMOTE="cowsay-episodes"
R2_BUCKET="cowsay-show-episodes"
PUBLIC_AUDIO_URL="https://episodes.cowsay.show"

# Transcription: providers/<TRANSCRIBE_PROVIDER>.sh
TRANSCRIBE_PROVIDER="elevenlabs"
TRANSCRIBE_LANGUAGE="ron"
ELEVENLABS_MODEL="scribe_v3"

# LLM (Claude Code CLI model alias)
LLM_MODEL="opus"

# Intro cut detection (detect-cut.sh)
CUT_MARKERS=(cut)        # words said on air right before the show starts
CUT_SEARCH_WINDOW=600    # seconds from the start of the raw audio to search in
CUT_PAD=0.3              # seconds of silence kept before the first word
CUT_DEFAULT=10           # fallback offset when nothing is detected

# Transcript granularity for the LLM: one [HH:MM:SS] line per this many seconds
TRANSCRIPT_BLOCK=10

# Episode lookup: title and stream from YouTube, audio from disk (stream.sh, find-audio.sh, unpublished.sh)
YOUTUBE_CHANNEL_STREAMS="https://www.youtube.com/@cowsay/streams"
STREAM_SEARCH_DEPTH=150        # latest streams to look at (two per episode: normal and vertical 📱)
AUDIO_SEARCH_DIRS=("$HOME/Downloads")
AUDIO_DURATION_TOLERANCE=30    # seconds a found file may differ from the stream duration
SITE_FEED_URL="https://cowsay.show/episodes.mp3.rss"
