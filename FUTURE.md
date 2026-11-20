# Proposed, not implemented

Features that came up while building the pipeline and were left for later, with what each would need.

## YouTube

| Feature | How | What it needs |
|---------|-----|---------------|
| **Thumbnail per episode** (cover with the episode number/title) | `thumbnails.set`, 50 quota units | A verified channel (phone verification). A generator for the image, e.g. ImageMagick on `cow-logo.png`. Today the thumbnails are kept as they are. |
| **Comment with the links** (site, podcast apps, Discord, Patreon) | `commentThreads.insert`, 50 units | Nothing more. The API **can't pin** a comment, so pinning stays manual. |
| **Captions on the vertical 📱 stream** | Same as the main video | Its own offset. The vertical stream starts a few seconds apart from the main one, so `yt-align.sh` would have to run against it too. |
| **Exact chapters on the vertical stream** | Same timestamps, shifted | The same per-video offset. Today it gets the main video's timestamps, which can be a few seconds off. |
| **Playlist for the vertical streams** | `playlistItems.insert` | A playlist to put them in (there's none). |

Not possible through the API at all: pinning comments, end screens, cards, monetization settings.

## Transcription

| Feature | How | What it needs |
|---------|-----|---------------|
| **Show vocabulary** | ElevenLabs gets names wrong, e.g. "Cowsay Show" becomes "Cause & Show". Fix it in the captions and the LLM input with a replacement list (`vocabulary.txt`), or with the provider's key-term option where it has one. | A list of names and terms, and a pass in `transcript.sh` |
| **Local transcription** | `providers/whisper.sh` is a stub for whisper.cpp / mlx-whisper | A local model and its output mapped to the normalized format (`providers/README.md`) |

## Other

| Feature | Notes |
|---------|-------|
| **Facebook description** | Still copied to the clipboard by `template-yt.sh`. The Graph API could post it, with a Meta app and a page token. |
| **R2 lock period** | `r2-uploads.sh cleanup` just tries and reports locked files. Reading the bucket's lock rule would need a token with bucket-admin rights. |
| **Episode 165 on YouTube** | It has a post on the site but no public video on the channel (neither a stream nor an upload), maybe private or deleted. The YouTube scripts can't see it. |
