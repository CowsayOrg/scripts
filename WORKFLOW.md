# Cowsay Show: Episode Publishing Workflow

This document describes how the `cowsay-scripts` toolkit turns a recorded live show into a published podcast episode: the overall pipeline, every utility script, its flags and arguments, and the external commands it relies on.

> All scripts are written for **zsh** and run **on macOS only**. They depend on `pbcopy`, `qlmanage`, `open` and `stat -f`. Run `episode.sh` and the older scripts from the repository root, because they source their helpers with relative paths (`. ./vars.sh`). The new scripts (`transcribe.sh`, `detect-cut.sh`, `topics.sh`) can be run from anywhere.

---

## 1. Overview

There is no manual step during the show anymore. After the show, the raw recording is transcribed once. That transcript is used to find where the show starts (the intro cut) and when each Trello topic was discussed. The topic times then feed the YouTube description, the website post and its chapter marks.

```
 BEFORE THE SHOW                         AFTER THE SHOW (episode.sh)
 ───────────────                         ───────────────────────────
 trello.sh ──► trello-<ep>.json ──────┐
                                      │   audio.sh
 stream.sh (YouTube title, url) ──────┤
 find-audio.sh (disk) or the stream ──┼─►  raw ─► transcribe.sh ─► detect-cut.sh ─► crop ─► shift transcript
                                      │        ─► preview y/n/<s> ─► compress ─► tag ─► R2 upload (-u)
                                      │
                                      └─► topics.sh (Claude) ─► Records-<ep>.csv ─► review y/n/e
                                                                     │
                                          format.sh ◄────────────────┘
                                          topics-<ep>.txt (YouTube, video time)
                                          topics-<ep>.md  (website)
                                          chapters-<ep>.yml
                                              │
                                          yt-align.sh    ─► youtube-offset-<ep>.txt (video vs raw)
                                          template-yt.sh ─► youtube-<ep>.txt → clipboard
                                          template-md.sh ─► post with chapters + video link → _posts/
                                          publish.sh     ─► preview, build, push _site → Cloudflare Pages
                                          youtube-update.sh ─► description, tags, category,
                                                               Lives playlist, captions → YouTube
```

All per-episode working files are kept in `$COWSAY_DIR/<episode_number>/`.

Only the episode number is needed: the title comes from the episode's YouTube stream, and the recording is found on disk or downloaded from the stream. `episode.sh -a` runs every episode that is on YouTube but not on cowsay.show yet.

### Three timelines

| Timeline | Starts at | Used for |
|----------|-----------|----------|
| **Raw** | start of `raw<ep>.mp3`, pre-show included | `transcript-<ep>.raw.json`, cut detection |
| **Podcast** | the intro cut | the published mp3, `transcript-<ep>.json/.txt`, `Records-<ep>.csv`, website chapters |
| **YouTube** | start of the YouTube video | description timestamps, captions |

- **Podcast time = raw time − cut.** The crop is a plain cut at an offset (`ffmpeg -ss <cut>`), stored in `cut-<ep>.txt` in seconds.
- **YouTube time = raw time − YouTube offset.** The YouTube video doesn't always start where the raw audio does. When the raw audio is YouTube's own download (the file in `~/Downloads`), they match. A local recording can have minutes of pre-show that the video doesn't: for episode 142 it was 171.2 s, almost exactly its intro cut.
- `yt-align.sh` measures the offset per episode into `youtube-offset-<ep>.txt`, and `format.sh` uses podcast time + cut − YouTube offset for the description.

---

## 2. Setup

### 2.1 Dependencies (`requirements.txt`)

| Tool        | Used by | Purpose |
|-------------|---------|---------|
| `ffmpeg`    | `audio.sh`, `transcribe.sh`, `detect-cut.sh`, `template-md.sh` | crop, compress and tag the mp3, make the upload copy, detect silences; `ffprobe` gets the duration |
| `yt-dlp`    | `audio.sh` | download audio from a YouTube URL |
| `curl`      | `providers/elevenlabs.sh`, `audio.sh`, `trello.sh` | ElevenLabs and Trello APIs; check the public mp3 URL |
| `claude`    | `detect-cut.sh`, `topics.sh` | Claude Code CLI, headless (`claude -p`), for the greeting and topic detection |
| `rclone`    | `audio.sh` | upload the final mp3 to Cloudflare R2 |
| `csvformat` | `format.sh` | change the delimiter of the Records CSV (part of csvkit) |
| `jq`        | most scripts | JSON processing |
| `python3`, `openssl` | `youtube-auth.sh` | the one-time YouTube login (local redirect listener, PKCE); both ship with macOS |
| `git`       | `publish.sh` | commit and push the built site and the site sources |
| `bundler`, `jekyll`, `octopod` | `publish.sh` | serve and build the podcast site |

The scripts do **not** install anything. If a tool is missing they print an error and exit.

### 2.2 `secrets.sh`

This file is gitignored. It holds the Trello credentials and the ElevenLabs API key:

```bash
#!/bin/zsh

API_KEY="1234"                 # Trello
TOKEN="123456789abc"           # Trello
ELEVENLABS_API_KEY="sk_..."    # ElevenLabs speech-to-text
```

### 2.3 `vars.sh`

| Variable | Meaning |
|----------|---------|
| `COWSAY_DIR` | Root for working files. Each episode gets its own subfolder |
| `COVER` | Cover image embedded into the mp3 (`$COWSAY_DIR/cow-logo.png`) |
| `COWSAY_SOURCE` | The `_posts/` directory of the cowsay site (Octopod/Jekyll) |
| `SITE_DIR` | The built site (`_site/` in the site sources). A git clone of `SITE_REPO` |
| `SITE_REPO` | GitHub repo of the built site (`CowsayOrg/CowsayOrg.github.io`). Cloudflare Pages deploys from it |
| `GITHUB_CERT_PATH` | SSH key used to push the built site and the site sources |
| `LOCAL_ADDRESS` | Local preview server address (`http://127.0.0.1:4000`) |
| `PUBLIC_ADDRESS` | Public site (`https://cowsay.show/`) |
| `R2_REMOTE` | rclone remote for Cloudflare R2 (`cowsay-episodes`) |
| `R2_BUCKET` | R2 bucket holding the episode mp3s (`cowsay-show-episodes`) |
| `PUBLIC_AUDIO_URL` | Public base URL of the mp3s (`https://episodes.cowsay.show`), matching `download_url` in the site's `_config.yml` |
| `TRANSCRIBE_PROVIDER` | Transcription adapter in `providers/` (`elevenlabs`) |
| `TRANSCRIBE_LANGUAGE` | Language code sent to the provider (`ron`, Romanian) |
| `ELEVENLABS_MODEL` | ElevenLabs model id (`scribe_v3`) |
| `LLM_MODEL` | Claude Code model alias for `claude -p` (`opus`) |
| `CUT_MARKERS` | Words said on air right before the show starts (`(cut)`) |
| `CUT_SEARCH_WINDOW` | Seconds from the start of the raw audio searched for the start of the show (`600`) |
| `CUT_PAD` | Seconds of silence kept before the first word (`0.3`) |
| `CUT_DEFAULT` | Fallback cut offset in seconds when nothing is detected (`10`) |
| `TRANSCRIPT_BLOCK` | Seconds per `[HH:MM:SS]` line in the transcript given to the LLM (`10`) |
| `YOUTUBE_CHANNEL_STREAMS` | The channel's streams page (`https://www.youtube.com/@cowsay/streams`) |
| `STREAM_SEARCH_DEPTH` | How many of the latest streams are listed (`150`, two per episode) |
| `AUDIO_SEARCH_DIRS` | Where `find-audio.sh` looks for recordings besides the episode folder (`~/Downloads`) |
| `AUDIO_DURATION_TOLERANCE` | Seconds a found recording may differ from the stream duration (`30`) |
| `YT_CLIENT_FILE`, `YT_TOKEN_FILE` | OAuth client and token for the YouTube API (`youtube-client.json`, `youtube-token.json`, gitignored) |
| `YT_LIVES_PLAYLIST` | The "Lives" playlist id |
| `YT_CATEGORY_ID` | YouTube category (`28`, Science & Technology) |
| `YT_LANGUAGE` | Video and caption language (`ro`) |
| `YT_BASE_TAGS` | Tags every episode gets, before the topic titles |
| `YT_CAPTION_NAME` | Name of our caption track, so reruns find it |
| `YT_ALIGN_MIN_MATCHES` | Words `yt-align.sh` needs to trust a measured offset (`30`) |
| `TRELLO_BOARD_ID` | The Trello board with the show lists (`KOfBQFVg`) |
| `TRELLO_LINK_EXCLUDE` | Regexes of links never published (Google Docs/Drive, `chatgpt.site`, Trello uploads) |
| `SHOW_TIMEZONE` | Time zone of the show (`Europe/Chisinau`). The post date is the stream's date there |
| `SITE_FEED_URL` | The site's podcast feed, the list of published episodes (`https://cowsay.show/episodes.mp3.rss`) |

### 2.4 Cloudflare R2 (audio hosting)

Episode mp3s are served from R2 at `https://episodes.cowsay.show`. `audio.sh -u` uploads with rclone. Set up the remote once with `rclone config`:

- name: `cowsay-episodes`
- type: `s3`, provider `Cloudflare`
- the account endpoint (`https://<account_id>.r2.cloudflarestorage.com`)
- an R2 API token's access key id and secret

The token needs **Object Read & Write** on the `cowsay-show-episodes` bucket. The upload skips bucket listing and existence checks, so listing permission is not required.

#### Object lock, revisions and the upload log

The bucket has an object lock: an uploaded file can't be deleted or replaced until the lock expires. So when an episode's audio is fixed and uploaded again, it goes up under a new name:

```
cow<ep>.mp3  →  cow<ep>-rev1.mp3  →  cow<ep>-rev2.mp3  …
```

`r2_upload` (in `audio.sh`, helpers in `r2.sh`) picks the name like this. For each candidate, in order, it asks the public URL for the file's ETag, which R2 sets to the file's MD5:
- the ETag equals the local file's MD5: this audio is already uploaded, so the upload is skipped;
- the file exists with other content, or the name is already in the log: it moves on to the next revision;
- the name is free: it uploads under that name.

Every upload is appended to **`$COWSAY_DIR/r2-uploads.log`**, a tab-separated file shared by all episodes:

```
<date UTC>  <action>  <episode>  <file name>  <md5>
```

| Action | Meaning |
|--------|---------|
| `uploaded` | uploaded by `audio.sh -u` |
| `found` | already in the bucket before the log existed (logged with its `Last-Modified` date the first time a revision is chosen) |
| `deleted` | removed by `r2-uploads.sh cleanup` |

An episode's current file is its latest `uploaded`/`found` entry. `template-md.sh` writes that name into the post's `audio: mp3:` field; it falls back to `cow<ep>.mp3` if nothing is logged. If the episode already has a post, `r2_upload` also patches its `audio: mp3:`, `filesize: mp3:` and `duration:` in place. Run `publish.sh` afterwards to deploy it. The feed, the JSON feed and the player all build the URL from that one field (`download_url` + `audio.mp3`).

Fixing an already published episode:

```bash
./audio.sh -e 173 -l ~/Downloads/173-fixed.mp3 -r -u   # uploads cow173-rev1.mp3, patches the post
./publish.sh 173
```

Note that `-r` with a different source file means a new transcription, which is paid. If the source recording didn't change (for example, you're only fixing the crop), keep the same `-l` file and the cached transcription is reused.

#### `r2-uploads.sh`: list and clean up old revisions

```bash
./r2-uploads.sh list [<episode>]     # every file still in the bucket, with upload date and current/old
./r2-uploads.sh cleanup -n           # dry run: show what would be deleted
./r2-uploads.sh cleanup [-v]         # delete the old revisions
```

`cleanup` deletes a file only if it's not its episode's current file and no post in `$COWSAY_SOURCE` references it. A file that's still locked is reported and kept; run `cleanup` again after the lock period. Deleted files are logged as `deleted`. The current file keeps its `-rev<n>` name, so it stays visible that the audio was modified.

### 2.5 Site deploy (Cloudflare Pages)

cowsay.show is served by Cloudflare Pages, which deploys from the GitHub repo `CowsayOrg/CowsayOrg.github.io`. That repo holds the **built** site, not the Jekyll sources. Locally it lives in `_site/` of the site sources, which must be a git clone of it. Jekyll keeps `.git` when it rebuilds `_site/`. Clone it once:

```bash
git clone git@github.com:CowsayOrg/CowsayOrg.github.io.git /Users/user/Code/Cowsay/cowsay-source/_site
```

The Jekyll sources live in a separate repo (`notanios/cowsay-source`). `octopod deploy` (rsync) is no longer used.

---

## 3. Shared helpers

These files are sourced, not executed.

| File | Provides | Behaviour |
|------|----------|-----------|
| `messages.sh` | `print_error`, `print_message`, `print_success` | Colored output: red, blue and green on black |
| `logging.sh` | `prepare_logging <name>` | Creates `.logs/` in the current directory, `cd`s into it, creates `<name>-YYYY-MM-DD-MM-SS.log` and sets its absolute path as `$LOG` |
| `utils.sh` | `prepare_dir <ep>` | Creates `$COWSAY_DIR/<ep>` if it is missing, `cd`s into it and sets `$EPISODE_DIR` |
| `transcript.sh` | transcript and LLM helpers | `validate_transcript`, `shift_transcript <in> <out> <offset>`, `transcript_to_text <in> <out>`, `claude_json <prompt> <schema>`, `fill_template <file> NAME value …` (replaces `@@NAME@@`), and the jq time helpers in `$JQ_TIME` (`hms`, `hmsms`, `secs`) |
| `vars.sh` | configuration | See [2.3](#23-varssh) |
| `secrets.sh` | credentials | See [2.2](#22-secretssh) |
| `providers/*.sh` | `provider_transcribe <audio> <json>` | Transcription adapters. See [5.4](#54-transcription-providers) |
| `prompts/*` | LLM prompts and JSON schemas | `cut.md` and `cut.schema.json` (greeting), `topics.md` and `topics.schema.json` (topic times). Edit the wording here, not in the scripts |

**Logging note:** the new scripts and `audio.sh` append to the log (`>> "$LOG"`). The older scripts still write with `>`, so their logs only keep the last command's output.

---

## 4. Step-by-step workflow

### Step 1: Prepare the topics in Trello (before the show)

Put the topics as cards in the show's list, named after the show date ("Nov 20"), with their links as attachments or in the description. `episode.sh` fetches them after the show by itself (`trello.sh`), so there's nothing to run beforehand.

### Step 2: Run the show

Nothing to record by hand. Optionally say **"cut"** on air right before the greeting. It makes the intro detection deterministic. Without it, Claude finds the greeting.

### Step 3: Run the pipeline (after the show)

```bash
./episode.sh -e 666 -u     # one episode
./episode.sh -a -u         # every unpublished episode
```

The title is taken from the YouTube stream. The recording is taken from the episode folder or `~/Downloads` (for example the file YouTube Studio downloads, `Live 666_ April's dry run.mp3`), or downloaded from the stream if neither has it. Use `-n`, `-l` or `-y` to override them.

Watch the console. Three steps stop and wait for you:

1. **Audio preview.** The detected cut point and how it was found are printed, and Quick Look plays the cropped file. Answer `y` to continue, or type a number of seconds to re-crop at that offset and preview again. Anything else stops.
2. **Topic review.** The topics with their start times, the quoted phrase each was found by, unplanned additions and skipped topics are printed. Answer `y`, or `e` to edit `Records-<ep>.csv` in a text editor first.
3. **Site preview.** The local site opens in the browser. Answer `y` to build and push it, which deploys it through Cloudflare Pages.

**Cost:** the ElevenLabs transcription is the only paid step, about one call per episode. It is cached by the md5 of the raw audio, so reruns, including `-r`, never pay twice for the same audio. The Claude calls run through the Claude Code CLI.

---

## 5. Utilities reference

### 5.1 `episode.sh`: orchestrator

Runs the whole post-show pipeline for one episode (`-e`) or for every unpublished episode (`-a`).

**Usage**

```bash
./episode.sh -e <number> [-n <title>] [-l <path> | -y <url>] [-u] [-t] [-r] [-v]
./episode.sh -a [-u] [-t] [-r] [-v]
```

| Flag | Argument | Required | Description |
|------|----------|----------|-------------|
| `-e` | `<number>` | `-e` or `-a` | Episode number |
| `-a` | – | `-e` or `-a` | Run every episode streamed on YouTube but not published on the site (see `unpublished.sh`) |
| `-n` | `<title>` | no | Override the title (default: the YouTube stream title). Only with `-e` |
| `-l` | `<path>` | no | Override the recording (default: found by `find-audio.sh`). Audio or video. Only with `-e` |
| `-y` | `<url>` | no | Download the audio from this URL instead. Only with `-e` |
| `-u` | – | no | Upload the final mp3 to R2 (passed to `audio.sh`) |
| `-t` | – | no | Test run (passed to `audio.sh`) |
| `-r` | – | no | Rebuild existing files and look the stream up again (passed to `stream.sh`, `audio.sh` and `topics.sh`). The transcription stays cached |
| `-v` | – | no | Verbose. Enables `set -x` and passes `-v` on to every step |

Without `-e` or `-a` it stops with an error and the usage. `-a` can't be combined with `-e`, `-n`, `-l` or `-y`, and `-l` with `-y`.

**Sequence (`-e`)**

0. `./stream.sh -e <ep> [-r] [-v]`, then:
   - the title: `-n`, otherwise the one in `stream-<ep>.json`;
   - the source: `-l` or `-y`, otherwise `./find-audio.sh -e <ep>`, otherwise the stream URL.

   If the stream lookup fails, the run only continues when both `-n` and `-l`/`-y` were given.
1. `./audio.sh -e <ep> -l <path> | -y <url> [-u] [-t] [-r] [-v]`
2. `./topics.sh -e <ep> [-r] [-v]`
3. Review of `topics-<ep>.review.txt`: `y` / `[n]` / `e`. Declining exits with code 3
4. `./yt-align.sh -e <ep> [-r] [-v]`
5. `./format.sh <ep> [-v]`
6. `./template-yt.sh <ep>`
7. `./template-md.sh <ep> "<title>"`
8. `./publish.sh <ep> [-v]`. Declining the site preview also exits with code 3
9. `./youtube-update.sh -e <ep> [-v]`. It asks before changing anything, and is skipped until the YouTube API setup is done

`set -euo pipefail` is active, so the first failing step aborts the pipeline.

**`-a`**

1. Lists the unpublished episodes with `./unpublished.sh` and asks before starting:
   - `y` runs all of them;
   - a list of numbers (`174 175`) runs only those;
   - anything else stops.
2. Runs `./episode.sh -e <ep>` with the same `-u -t -r -v` for each, oldest first. Each episode has its own prompts and is published on its own.
3. A failed episode doesn't stop the others. At the end it prints which episodes are done, which stopped at a review (exit code 3), and which failed.

### 5.1.1 `stream.sh`: the episode's YouTube stream

```bash
./stream.sh -e <episode> [-r] [-v]
```

It lists the latest `$STREAM_SEARCH_DEPTH` streams of `$YOUTUBE_CHANNEL_STREAMS` with `yt-dlp --flat-playlist`, a quick listing that needs no API key. It then picks the stream whose title has the episode number after "live", case-insensitive, so it matches "Live 173: …" and "LIVE DE URGENȚĂ 174: …". The vertical copy, whose title ends in "📱", is skipped.

- **Output:** `stream-<ep>.json` `{id, url, title, duration, episode, vertical_id, streamed_at, date}`. It's reused on later runs; `-r` looks the stream up again.
- **Stream date:** `streamed_at` is when the stream started (yt-dlp's `release_timestamp`; one extra call, since the channel listing has no dates), and `date` is that day in `$SHOW_TIMEZONE`. It's the post date. Files saved before the date existed get it on the next run.
- **Cache:** the channel listing is kept in `$COWSAY_DIR/.streams.json` for 10 minutes, so `-a` lists the channel only once. The helpers are in `yt-helpers.sh`; the API helpers are in `yt-api.sh`.
- **No match:** it fails with a hint to use `-n` and `-l`/`-y`.

### 5.1.2 `find-audio.sh`: the recording on disk

```bash
./find-audio.sh -e <episode> [-v]
```

Prints the recording's path, or nothing if there is none, in which case it's downloaded from the stream. Messages go to stderr. The search order:

1. `raw<ep>.mp3` from an earlier run.
2. Any other audio or video file in the episode folder (generated files excluded).
3. `$AUDIO_SEARCH_DIRS` (`~/Downloads`). A file matches if its name either:
   - equals the stream title, ignoring case and punctuation (YouTube Studio replaces `:` and `?` with `_`), or
   - contains "live <ep>".

Audio files come before video files, then newest first. In steps 2 and 3, a file must last as long as the stream within `$AUDIO_DURATION_TOLERANCE` seconds; otherwise it's skipped with a note. A video (`Live 168.mp4`) is fine, because `audio.sh` extracts the audio.

### 5.1.3 `unpublished.sh`: episodes not on the site yet

```bash
./unpublished.sh [-v]
```

Prints, one per line and oldest first, the episodes streamed on YouTube that aren't in the site feed (`$SITE_FEED_URL`). It reads the published numbers from the feed's post links (`/2026/09/08/173.html`).

The feed only holds the latest 20 episodes, so only streams newer than the oldest one in it are considered. Episodes streamed but never published inside that window also show up; for example, 156, 157, 160, 161 and 167 at the time of writing. Answer with only the numbers you want at the `-a` prompt.

---

### 5.2 `audio.sh`: audio builder and uploader

Produces the final tagged mp3, the transcripts and the cut offset, and optionally uploads the mp3.

**Usage**

```bash
./audio.sh -e <number> (-l <path> | -y <url>) [-u] [-t] [-r] [-v]
```

| Flag | Argument | Required | Description |
|------|----------|----------|-------------|
| `-e` | `<number>` | yes | Episode number |
| `-l` | `<path>` | one of `-l`/`-y` | Local source recording, audio or video. An mp3 is copied, not moved; anything else is converted to mp3, keeping only the audio |
| `-y` | `<url>` | one of `-l`/`-y` | YouTube URL to download |
| `-u` | – | no | Upload the final mp3 to R2 |
| `-t` | – | no | Test run. Fast stream-copy crop, no compression, no cleanup |
| `-r` | – | no | Rebuild the raw copy, cut point, crop, compression and tags |
| `-v` | – | no | Verbose (`set -x`), also passed to `transcribe.sh` and `detect-cut.sh` |

**Files** (in `$COWSAY_DIR/<ep>/`)

| File | Stage |
|------|-------|
| `raw<ep>.mp3` | Unprocessed source (video timeline) |
| `transcript-<ep>.raw.json` | Transcript of the raw audio (from `transcribe.sh`) |
| `cut-<ep>.txt`, `cut-<ep>.info` | Cut offset in seconds, and how it was found (from `detect-cut.sh`) |
| `cropped<ep>.mp3` | Intro removed |
| `transcript-<ep>.json`, `transcript-<ep>.txt` | Transcript shifted to the podcast timeline; JSON, and `[HH:MM:SS]` text for the LLM |
| `compressed<ep>.mp3` | Compressor applied |
| `cow<ep>.mp3` | Tagged, with cover art. This is the deliverable |

**Stages**

| # | Function | What it does | Command |
|---|----------|--------------|---------|
| 1 | `prepare_raw` | Copies `-l` or downloads `-y` into `raw<ep>.mp3`. Skipped if it exists, unless `-r` is given | `cp` / `yt-dlp -x --audio-format mp3` |
| 2 | `transcribe_raw` | Transcribes the raw audio. Cached by audio md5 | `transcribe.sh` |
| 3 | `detect_cut` | Finds the start of the show. Rerun if the transcript is newer or `-r` is given | `detect-cut.sh` |
| 4 | `crop` | Cuts at the offset. In test mode it uses a fast stream copy | `ffmpeg -i raw -ss <cut> cropped` |
| 5 | `shift_to_podcast_timeline` | Shifts the transcript by `−cut` and renders the text version | `jq` (`transcript.sh`) |
| 6 | `preview` | Prints the cut and its evidence and plays the crop in Quick Look. `y` continues; a number re-crops at that offset (method `manual`); anything else cleans up and exits | `qlmanage -p` |
| 7 | `add_compression` | Dynamic-range compression. Skipped in test mode | `ffmpeg -af acompressor` |
| 8 | `add_metadata` | Embeds the cover and tags: title from `stream-<ep>.json` (else `Live <ep>`), artist `Cowsay Show`, genre `Podcast`, year | `ffmpeg -map 0 -map 1 -metadata … -c copy` |
| 9 | `r2_upload` | Only with `-u`. Picks the file name (`cow<ep>.mp3`, or `cow<ep>-rev<n>.mp3` for a fix; skips the upload if the same audio is already there), uploads it, checks that the public URL answers HTTP 200, logs it in `r2-uploads.log`, and patches the existing post if there is one. See 2.4 | `rclone copyto`, `curl -I` |
| 10 | `clean` | Deletes the cropped and compressed files. Skipped in test mode | `rm -f` |

Stages 4, 7 and 8 rebuild only when their output is missing, older than their input, or `-r` is given. A new cut point therefore re-crops automatically. Every `ffmpeg` call uses `-nostdin`, so it never swallows your answers to the prompts.

---

### 5.3 `transcribe.sh`: speech-to-text front end

**Usage**

```bash
./transcribe.sh -e <episode> -i <audio_in> -o <json_out> [-v]
```

| Flag | Argument | Required | Description |
|------|----------|----------|-------------|
| `-e` | `<episode>` | yes | Episode number. Files are relative to `$COWSAY_DIR/<ep>/` |
| `-i` | `<audio_in>` | yes | Audio to transcribe |
| `-o` | `<json_out>` | yes | Normalized transcript to write |
| `-v` | – | no | Verbose |

**Sequence**

1. If `<json_out>` exists and `<json_out>.md5` matches the md5 of the input, it exits without calling the provider.
2. It makes a light mono 16 kHz copy for the upload (`ffmpeg -ac 1 -ar 16000 -b:a 48k`). Timing is unchanged.
3. It sources `providers/$TRANSCRIBE_PROVIDER.sh` and calls `provider_transcribe`.
4. It validates the result (`validate_transcript`) and stores the md5.

`TRANSCRIBE_FORCE=1 ./transcribe.sh …` forces a new paid call.

### 5.4 Transcription providers

Adapters live in `providers/`. Each one is sourced by `transcribe.sh` and defines `provider_transcribe <audio_in> <json_out>`, which writes the **normalized transcript**:

```json
{ "provider": "elevenlabs", "language": "ron",
  "segments": [ { "start": 12.34, "end": 15.10, "text": "…", "speaker": "speaker_0",
                  "words": [ { "text": "Salut", "start": 12.34, "end": 12.70 } ] } ] }
```

`segments` with `start`, `end` and `text` are required; `speaker` and `words` are optional. Switching engines means adding `providers/<name>.sh` and setting `TRANSCRIBE_PROVIDER`. See `providers/README.md`.

| Provider | Status | Notes |
|----------|--------|-------|
| `elevenlabs` | ✅ | `POST https://api.elevenlabs.io/v1/speech-to-text` with `model_id=$ELEVENLABS_MODEL`, `language_code`, `timestamps_granularity=word` and `diarize=true`. Keeps the raw response as `<out>.provider.json` and reuses it for the same audio, so a fix in the conversion never needs a new paid call. It groups words into segments on a speaker change, a pause over 1.5 s or a sentence end |
| `whisper` | stub | Placeholder for a local `whisper.cpp`/`mlx-whisper` adapter |

---

### 5.5 `detect-cut.sh`: intro cut detection

**Usage**

```bash
./detect-cut.sh -e <episode> [-v]
```

| Flag | Argument | Required | Description |
|------|----------|----------|-------------|
| `-e` | `<episode>` | yes | Episode number |
| `-v` | – | no | Verbose |

- **Inputs:** `transcript-<ep>.raw.json`, `raw<ep>.mp3`.
- **Outputs:** `cut-<ep>.txt` (seconds, e.g. `171.892`) and `cut-<ep>.info` (`<method><TAB><evidence>`).

It tries each step in order and stops at the first that finds a point:

| # | Method | How |
|---|--------|-----|
| 1 | `marker` | Finds the **last** word in `CUT_MARKERS` (default `cut`, case and punctuation ignored) within the first `CUT_SEARCH_WINDOW` seconds. The candidate is the start of the next word |
| 2 | `greeting` | Sends the first `CUT_SEARCH_WINDOW` seconds, as `[seconds] speaker: text` lines, to Claude (`prompts/cut.md`). Claude returns the start of the on-air greeting with a verbatim quote and a confidence, and the answer is snapped to the nearest segment start |
| 3 | snap | Runs `ffmpeg silencedetect=noise=-35dB:d=0.3` over the 8 s before the candidate and moves the cut into the last silence before the first word, keeping `CUT_PAD` seconds of it |
| 4 | `default` | Uses `CUT_DEFAULT` with a warning |

At the audio preview you can override the cut with a number of seconds, which is recorded with method `manual`.

---

### 5.6 `topics.sh`: topic timestamps

**Usage**

```bash
./topics.sh -e <episode> [-r] [-v]
```

| Flag | Argument | Required | Description |
|------|----------|----------|-------------|
| `-e` | `<episode>` | yes | Episode number |
| `-r` | – | no | Regenerate `Records-<ep>.csv` even if it exists |
| `-v` | – | no | Verbose |

An existing `Records-<ep>.csv`, for example a manual export, is kept unless `-r` is given.

**Inputs:**

- `transcript-<ep>.txt` and `transcript-<ep>.json` (podcast timeline);
- `trello-<ep>.json` from `trello.sh` (optional; the old `trello_cards_<ep>.ssv` is read too). Without it, Claude discovers the topics itself, and they have no links.

**Sequence**

1. Numbers the Trello cards and gives Claude each card's name and the start of its description. The links are not sent.
2. Fills `prompts/topics.md` and calls `claude -p --model $LLM_MODEL --tools "" --output-format json --json-schema prompts/topics.schema.json`.
3. Claude returns, for every discussed topic:
   - its start;
   - its own **title**, a short Romanian headline of 3 to 8 words saying what was actually discussed;
   - the **card** it covers, or none;
   - a short verbatim evidence quote.

   It also returns the cards that weren't discussed, and the outro start. One card can be two topics, and substantial topics without a card are included.
4. Validates the result: every time falls inside the audio, and every card number exists.
5. **Refines** each start: it looks for the evidence quote in the segment-level transcript within that line's block and uses the segment's exact start, with milliseconds.
6. **Links:** each topic gets its card's links, copied from `trello-<ep>.json`, so Claude never types a URL.
7. Writes the outputs.

**Outputs**

| File | Content |
|------|---------|
| `Records-<ep>.csv` | Same format as the old Records app export: `"HH:MM:SS.mmm","Title"[,"link1 link2 …"]` (links separated by spaces), with Intro at `00:00:00.000` first, topics in time order and Outro last |
| `topics-<ep>.review.txt` | Readable summary for the review step: each topic with its card and number of links, and the cards not discussed |
| `topics-<ep>.llm.json`, `topics-<ep>.timed.json` | Claude's raw answer and the refined times |

---

### 5.7 `format.sh`: show notes and chapters

**Usage**

```bash
./format.sh <episode_number> [-v]
```

**Input:** `Records-<ep>.csv`, made by `topics.sh` or exported by hand, plus `cut-<ep>.txt` and `youtube-offset-<ep>.txt`.

**Row rules**

| Column 2 value | Result |
|----------------|--------|
| `moment`, `cut`, *(empty)* | Skipped |
| `Intro` / `Outro` | YouTube line and chapter |
| topic, no link | `HH:MM:SS - Topic` → YouTube; `* Topic` → website; chapter |
| topic + link | `HH:MM:SS - Topic: link` → YouTube; `* [Topic](link)` → website; chapter |

**Outputs**

| File | Content |
|------|---------|
| `topics-<ep>.txt` | YouTube list on the **YouTube timeline**: Records time + cut (`cut-<ep>.txt`) − YouTube offset (`youtube-offset-<ep>.txt`, from `yt-align.sh`), rounded; Intro is always `00:00:00`, as YouTube chapters require. Without an offset file the video is assumed to start with the raw audio. Old `HH:MM:SS` cut files from the manual era are read as seconds; without an offset file they shift nothing, as before |
| `topics-<ep>.md` | Website bullet list |
| `chapters-<ep>.yml` | Octopod chapter lines `  - 'HH:MM:SS.mmm Title'` (podcast time, sorted; `'` doubled for YAML) |

---

### 5.7.1 `yt-align.sh`: where the YouTube video starts

```bash
./yt-align.sh -e <episode> [-r] [-v]
```

It measures the YouTube offset: how many seconds into `raw<ep>.mp3` the YouTube video starts.
- **With captions:** it downloads YouTube's automatic Romanian captions with yt-dlp (free, no login) and matches words that occur only once in both them and `transcript-<ep>.raw.json`. The offset is the median time difference. It's trusted with at least `$YT_ALIGN_MIN_MATCHES` (30) matches, 80% of them within 2 s of the median. Episode 142: 489 of 492 words, 171.239 s.
- **Without captions:** YouTube adds them a while after the stream. It then falls back to the difference in duration, if that's over 15 s, and otherwise to 0. Run it again with `-r` once YouTube has captions.
- **Output:** `youtube-offset-<ep>.txt` (seconds, `%.3f`) and `youtube-offset-<ep>.info` (method and evidence). It's reused unless `-r` is given.

### 5.8 `template-yt.sh`: YouTube/Facebook description

**Usage**

```bash
./template-yt.sh <episode_number>
```

- **Input:** `topics-<ep>.txt`.
- **Output:** `youtube-<ep>.txt`: a fixed Romanian header, the topics and a footer. It is copied to the clipboard with `pbcopy`.

### 5.9 `template-md.sh`: website post

**Usage**

```bash
./template-md.sh <episode_number> ["<episode_title>"]
```

The title is optional; without it, the title in `stream-<ep>.json` is used.

- **Inputs:** `cow<ep>.mp3`, `topics-<ep>.md`, `chapters-<ep>.yml` (optional) and `r2-uploads.log` (the uploaded file name).
- **Output:** `YYYY-MM-DD-<ep>.md`, copied to `$COWSAY_SOURCE`. It contains:
  - front matter with the title (`'` doubled for YAML), date, `duration` (from `ffprobe`), `audio: mp3` (the current R2 name, for example `cow173-rev1.mp3`), `filesize` (from `stat -f%z`) and **`chapters`**;
  - the Podigee player tag;
  - the header, the topics and the footer.

**Post date:** the day the episode was streamed (`date` in `stream-<ep>.json`), so an old episode run through the scripts isn't dated today. It falls back to today only without a stream date.

If a post for the episode already exists in `_posts`, it's regenerated in place, so there's never a second post for the same episode. Its date depends on whether it's committed:
- **Committed:** it keeps its date even when that differs from the stream date. The date is in its URL and its feed id, and changing them would make podcast apps see a new episode. You get a warning.
- **Not committed:** a post with the wrong date is moved to the stream date.

The Podigee player shows the chapters (Octopod reads `chapter[0..12]` as the start), and the RSS feed publishes them as `psc:chapters`.

### 5.10 `publish.sh`: site preview, build, deploy and git push

**Usage**

```bash
./publish.sh <episode_number> [-v]
```

| # | Action | Command |
|---|--------|---------|
| 1 | Load the GitHub key | `ssh-add $GITHUB_CERT_PATH` |
| 2 | Go to the site root and check that `$SITE_DIR` is a git repo | `cd`, `git rev-parse` |
| 3 | Start the local server, wait until it's up, and open the preview. If the server dies or doesn't start within 2 minutes, it stops with an error | `bundle exec octopod s &`, `open` |
| 4 | Ask `y/[n]`, then stop the server. Any answer other than `y` exits with code 3 | `read`, `kill` |
| 5 | Build the site into `$SITE_DIR` | `bundle exec octopod b` |
| 6 | Deploy: commit and push `_site` to `$SITE_REPO`, which Cloudflare Pages deploys | `git -C $SITE_DIR add -A`, `commit`, `push` |
| 7 | Open the live site, then commit and push the site sources | `open`, `git add .`, `commit`, `push` |

The preview server keeps running until you answer, so the page can be browsed. It's also stopped when the script ends any other way (an `EXIT` trap). `set -x` is on only with `-v`.

**No job control (`set -m`).** An earlier version turned it on to manage the background server. With job control, a `publish.sh` started from `episode.sh` is not in the terminal's foreground, and macOS stops it (`SIGTTIN`, state `T` in `ps`) as soon as it reads the answer. The run then hangs with no prompt, as happened with episode 174. Don't add it back. Background jobs and `kill` work without it.

### 5.10.1 `youtube-update.sh`: update the YouTube videos

```bash
./youtube-update.sh -e <episode> [-n] [-r] [-v]
```

It updates, through the YouTube Data API:

| What | Main video | Vertical 📱 video |
|------|------------|-------------------|
| Description: `youtube-<ep>.txt` with `🎧 Episodul ca podcast: <post url>` on top. The timestamps make YouTube's chapters | yes | yes, with `▶️ Versiunea orizontală: <main video>` on top |
| Tags: `$YT_BASE_TAGS`, then the topic titles without the `[Name]` prefix and without commas (a comma in a tag breaks the whole list), up to YouTube's 500 characters. Compared regardless of order, since YouTube returns them sorted | yes | yes |
| Category `$YT_CATEGORY_ID` (28, Science & Technology), language `$YT_LANGUAGE` (ro) | yes | yes |
| "Lives" playlist (`$YT_LIVES_PLAYLIST`), skipped if it's already there | yes | no |
| Captions `$YT_CAPTION_NAME` from `transcript-<ep>.raw.json`, shifted to the YouTube timeline, at most about 6 s or 80 characters per cue (`youtube-captions-<ep>.srt`) | yes | no |

The title is left as it is on YouTube.

- **Review first:** it shows a diff between what's on YouTube and what's proposed, then asks y/[n]. Nothing is written without a `y`.
- **Flags:** `-n` is a dry run; without the login it shows the proposed content only. `-r` replaces our caption track if it's already there. Without `-r`, an existing track is kept.
- **Before the one-time setup:** it prints a note and exits 0, so `episode.sh` keeps working.
- **Quota:** about 600 of the 10,000 daily units per episode: 50 per video update, 51 for the playlist, 450 for the captions.

### 5.10.2 `youtube-backfill.sh`: complete the Lives playlist

```bash
./youtube-backfill.sh [-n] [-v]
```

It adds, oldest first, the episode streams newer than the newest episode already in "Lives". Older ones are left alone. It lists them and asks first; `-n` only lists them. The playlist is read with yt-dlp (free), and each insert costs 50 units. In November 2026, episodes 155 to 174 were missing: 19 videos, since 165 has no video.

### 5.10.3 YouTube API setup (once)

Writing to YouTube needs OAuth; an API key can only read.

1. In [Google Cloud Console](https://console.cloud.google.com/), pick or create a project and enable **YouTube Data API v3** (APIs & Services → Library).
2. Set up the **OAuth consent screen** (Google Auth Platform → Branding / Audience):
   - type External;
   - add your account as a test user;
   - then **Publish app** so it's "In production". In "Testing" mode the login expires after 7 days. An unverified app is fine for your own use; Google shows a warning once at login.
3. Under **Clients**, create an OAuth client of type **Desktop app**. Download its JSON to `youtube-client.json` in the scripts folder. It's gitignored.
4. Run `./youtube-auth.sh`. The browser opens; sign in and **choose the Cowsay channel** if Google asks which account or brand account. The refresh token is saved to `youtube-token.json` (gitignored, mode 600), and the script prints the channel it logged in as.

The scripts then refresh the access token by themselves, with no browser (`yt-api.sh`). If it ever stops working, run `./youtube-auth.sh` again.

### 5.11 `trello.sh`: Trello topics and their links

```bash
./trello.sh -e <episode> [-l "<list name>"] [-v]
./trello.sh "<list name>" <episode>      # old form, still works (Raycast)
```

The board (`$TRELLO_BOARD_ID`) has one list per show, named after the show date in various forms ("Nov 20", "28 July", "16th of September", "8 окт").
- **Finding the list:** without `-l`, it matches the day and month in each list's name, including archived lists, against the stream date from `stream-<ep>.json`. If it has no date yet, it runs `stream.sh`. If several lists match, it takes the one created last before the stream; the creation time is encoded in the Trello id. Months can be written in English, Romanian or Russian.
- **Links of a card:** its attachments, then the URLs in its description.
  - Tracking parameters (`utm_*`, `fbclid`, `gclid`) are removed, then duplicates.
  - Links matching `$TRELLO_LINK_EXCLUDE` are dropped. These are private prep notes that must not end up in a public description: Google Docs and Drive, `chatgpt.site` pages, and uploaded files.
- **Output:** `trello-<ep>.json`: `{list: {id, name}, cards: [{name, links, desc}]}`. Auth comes from `API_KEY` and `TOKEN` in `secrets.sh`.

`episode.sh` runs it before `topics.sh`. If it finds no list, the run continues without links.

**How links are shown** (`format.sh`):
- with one link, the whole title is the link: `* [Title](url)` on the site, `Title: url` on YouTube;
- with several, they're listed: `* Title ([link1](url1), [link2](url2))` on the site, `Title: url1, url2` on YouTube.

### 5.12 `.mcp.json` and `trello-mcp.sh`

Claude Code's project MCP config. It loads the Trello MCP server (a local `mcp-server-trello` build, board `KOfBQFVg`) when Claude Code runs in this directory. The shell scripts don't use it.

`.mcp.json` holds no credentials: it starts `trello-mcp.sh`, which reads `TRELLO_MCP_API_KEY` and `TRELLO_MCP_TOKEN` from `secrets.sh` and runs the server with them.

---

## 6. Raycast integration

`format.sh`, `template-yt.sh`, `template-md.sh`, `publish.sh` and `trello.sh` carry `@raycast.*` header comments, so they can be added as Raycast Script Commands in the `cowsay-audio` package.

---

## 7. File map for one episode

All files below are in `$COWSAY_DIR/<ep>/`, except the post copy, which goes to `_posts/`.

| File | Produced by | Consumed by |
|------|-------------|-------------|
| `trello-<ep>.json` (old: `trello_cards_<ep>.ssv`) | `trello.sh` | `topics.sh` |
| `youtube-offset-<ep>.txt`, `.info`, `youtube-autosubs-<ep>.*.json3` | `yt-align.sh` | `format.sh`, `youtube-update.sh` |
| `youtube-captions-<ep>.srt` | `youtube-update.sh` | YouTube |
| `stream-<ep>.json` | `stream.sh` | `episode.sh`, `find-audio.sh`, `audio.sh` (ID3 title), `template-md.sh` |
| `raw<ep>.mp3` | `audio.sh` | `transcribe.sh`, `detect-cut.sh`, `audio.sh` |
| `transcript-<ep>.raw.json` (+ `.md5`, `.provider.json`) | `transcribe.sh` | `detect-cut.sh`, `audio.sh` |
| `cut-<ep>.txt`, `cut-<ep>.info` | `detect-cut.sh` / preview override | `audio.sh`, `format.sh` |
| `transcript-<ep>.json`, `transcript-<ep>.txt` | `audio.sh` | `topics.sh` |
| `cropped<ep>.mp3`, `compressed<ep>.mp3` | `audio.sh` | `audio.sh` (deleted by `clean`) |
| `cow<ep>.mp3` | `audio.sh` | R2 (as `cow<ep>.mp3` or `cow<ep>-rev<n>.mp3`), `template-md.sh` |
| `$COWSAY_DIR/r2-uploads.log` (all episodes) | `audio.sh -u`, `r2-uploads.sh` | `template-md.sh`, `r2-uploads.sh` |
| `Records-<ep>.csv` | `topics.sh` (or a manual export) | `format.sh` |
| `topics-<ep>.review.txt`, `.llm.json`, `.timed.json` | `topics.sh` | review step |
| `topics-<ep>.txt` | `format.sh` | `template-yt.sh` |
| `topics-<ep>.md`, `chapters-<ep>.yml` | `format.sh` | `template-md.sh` |
| `youtube-<ep>.txt` | `template-yt.sh` | clipboard → YouTube/Facebook |
| `YYYY-MM-DD-<ep>.md` | `template-md.sh` | site `_posts/` → `publish.sh` |
| `_site/` (built site) | `publish.sh` (`octopod b`) | `CowsayOrg.github.io` → Cloudflare Pages |

---

## 8. Known issues

| # | Issue | Effect |
|---|-------|--------|
| 1 | `-t` does not suppress `-u` | A test run still uploads if `-u` is given |
| 2 | The older scripts log with `>` | Their logs keep only the last command's output |
| 3 | Editing a script while `episode.sh` is running | zsh reads a script while running it, so editing it mid-run can make the running copy go wrong. Edit between runs |
| 4 | Topic starts are the moment a topic is *introduced*, as Claude reads it | When the hosts lead into a topic for a while before naming it, the time can fall about 20 s either side of where a human would put the mark. Check the review step and press `e` to adjust |

---

### Don't forget to have fun ;) 🐮
