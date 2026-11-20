# Cowsay Show: Episode Publishing Workflow

This document describes how the `cowsay-scripts` toolkit turns a recorded live show into a published podcast episode: the overall pipeline, every utility script, its flags and arguments, and the external commands it relies on.

> All scripts are written for **zsh** and run **on macOS only**. They depend on `pbcopy`, `qlmanage`, `open` and `stat -f`. Run `episode.sh` and the older scripts from the repository root, because they source their helpers with relative paths (`. ./vars.sh`). The new scripts (`transcribe.sh`, `detect-cut.sh`, `topics.sh`) can be run from anywhere.

---

## 1. Overview

There is no manual step during the show anymore. After the show, the raw recording is transcribed once. That transcript is used to find where the show starts (the intro cut) and when each Trello topic was discussed. The topic times then feed the YouTube description, the website post and its chapter marks.

```
 BEFORE THE SHOW                         AFTER THE SHOW (episode.sh)
 ───────────────                         ───────────────────────────
 trello.sh ──► trello_cards_<ep>.ssv ─┐
                                      │   audio.sh
 raw recording (-l mp3 | -y url) ─────┼─►  raw ─► transcribe.sh ─► detect-cut.sh ─► crop ─► shift transcript
                                      │        ─► preview y/n/<s> ─► compress ─► tag ─► R2 upload (-u)
                                      │
                                      └─► topics.sh (Claude) ─► Records-<ep>.csv ─► review y/n/e
                                                                     │
                                          format.sh ◄────────────────┘
                                          topics-<ep>.txt (YouTube, video time)
                                          topics-<ep>.md  (website)
                                          chapters-<ep>.yml
                                              │
                                          template-yt.sh ─► youtube-<ep>.txt → clipboard
                                          template-md.sh ─► post with chapters → _posts/
                                          publish.sh     ─► preview, build, push _site → Cloudflare Pages
```

All per-episode working files are kept in `$COWSAY_DIR/<episode_number>/`.

### Two timelines

| Timeline | Starts at | Used for |
|----------|-----------|----------|
| **Video** (raw) | start of the live-stream recording, pre-show included | `transcript-<ep>.raw.json`, cut detection, YouTube description |
| **Podcast** | the intro cut | the published mp3, `transcript-<ep>.json/.txt`, `Records-<ep>.csv`, website chapters |

The crop is a plain cut at an offset (`ffmpeg -ss <cut>`), so podcast time = video time − cut. The cut offset is stored in `cut-<ep>.txt` in seconds. `format.sh` adds it back for the YouTube timestamps.

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

### Step 1: Fetch topics from Trello (before the show)

```bash
./trello.sh '<List Name>' <episode_number>
# e.g.
./trello.sh '11 April' 666
```

### Step 2: Run the show

Nothing to record by hand. Optionally say **"cut"** on air right before the greeting. It makes the intro detection deterministic. Without it, Claude finds the greeting.

### Step 3: Run the pipeline (after the show)

```bash
./episode.sh -e 666 -n "Live 666: April's dry run" -l ~/Downloads/666.mp3 -u
```

Watch the console. Three steps stop and wait for you:

1. **Audio preview.** The detected cut point and how it was found are printed, and Quick Look plays the cropped file. Answer `y` to continue, or type a number of seconds to re-crop at that offset and preview again. Anything else stops.
2. **Topic review.** The topics with their start times, the quoted phrase each was found by, unplanned additions and skipped topics are printed. Answer `y`, or `e` to edit `Records-<ep>.csv` in a text editor first.
3. **Site preview.** The local site opens in the browser. Answer `y` to build and push it, which deploys it through Cloudflare Pages.

**Cost:** the ElevenLabs transcription is the only paid step, about one call per episode. It is cached by the md5 of the raw audio, so reruns, including `-r`, never pay twice for the same audio. The Claude calls run through the Claude Code CLI.

---

## 5. Utilities reference

### 5.1 `episode.sh`: orchestrator

Runs the whole post-show pipeline.

**Usage**

```bash
./episode.sh -e <number> -n <title> (-l <path> | -y <url>) [-u] [-t] [-r] [-v]
```

| Flag | Argument | Required | Description |
|------|----------|----------|-------------|
| `-e` | `<number>` | yes | Episode number |
| `-n` | `<title>` | yes | Episode title, used in the website post |
| `-l` | `<path>` | one of `-l`/`-y` | Local recording to use as the source |
| `-y` | `<url>` | one of `-l`/`-y` | YouTube URL to download the audio from |
| `-u` | – | no | Upload the final mp3 to R2 (passed to `audio.sh`) |
| `-t` | – | no | Test run (passed to `audio.sh`) |
| `-r` | – | no | Rebuild existing files (passed to `audio.sh` and `topics.sh`). The transcription stays cached |
| `-v` | – | no | Verbose. Enables `set -x` and passes `-v` on to every step |

If both `-l` and `-y` are given, `-l` wins.

**Sequence**

1. `./audio.sh -e <ep> -l <path> | -y <url> [-u] [-t] [-r] [-v]`
2. `./topics.sh -e <ep> [-r] [-v]`
3. Review of `topics-<ep>.review.txt`: `y` / `[n]` / `e`
4. `./format.sh <ep> [-v]`
5. `./template-yt.sh <ep>`
6. `./template-md.sh <ep> "<title>"`
7. `./publish.sh <ep> [-v]`

`set -euo pipefail` is active, so the first failing step aborts the pipeline.

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
| `-l` | `<path>` | one of `-l`/`-y` | Local source recording. It is copied, not moved |
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
| 8 | `add_metadata` | Embeds the cover and tags: title `Live <ep>`, artist `Cowsay Show`, genre `Podcast`, year | `ffmpeg -map 0 -map 1 -metadata … -c copy` |
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
- `trello_cards_<ep>.ssv` (optional). Without it, Claude discovers the topics itself, without links.

**Sequence**

1. Parses the Trello cards into `[{title, link}]` (the first attachment URL is the link).
2. Fills `prompts/topics.md` and calls `claude -p --model $LLM_MODEL --tools "" --output-format json --json-schema prompts/topics.schema.json`.
3. Claude returns, for every topic, its start, whether it was planned or skipped, and a short verbatim evidence quote, plus the outro start. Unplanned substantial topics are added.
4. Validates the result: every discussed topic has a start, and all times fall inside the audio.
5. **Refines** each start: it looks for the evidence quote in the segment-level transcript within that line's block and uses the segment's exact start, with milliseconds.
6. Writes the outputs.

**Outputs**

| File | Content |
|------|---------|
| `Records-<ep>.csv` | Same format as the old Records app export: `"HH:MM:SS.mmm","Title"[,"link"]`, with Intro at `00:00:00.000` first, topics in time order and Outro last. Skipped topics are left out |
| `topics-<ep>.review.txt` | Readable summary for the review step |
| `topics-<ep>.llm.json`, `topics-<ep>.timed.json` | Claude's raw answer and the refined times |

---

### 5.7 `format.sh`: show notes and chapters

**Usage**

```bash
./format.sh <episode_number> [-v]
```

**Input:** `Records-<ep>.csv`, made by `topics.sh` or exported by hand, plus `cut-<ep>.txt`.

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
| `topics-<ep>.txt` | YouTube list on the **video timeline**: Records time + the cut offset from `cut-<ep>.txt`. Old `HH:MM:SS` cut files from the manual era are not added |
| `topics-<ep>.md` | Website bullet list |
| `chapters-<ep>.yml` | Octopod chapter lines `  - 'HH:MM:SS.mmm Title'` (podcast time, sorted; `'` doubled for YAML) |

---

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
./template-md.sh <episode_number> "<episode_title>"
```

- **Inputs:** `cow<ep>.mp3`, `topics-<ep>.md`, `chapters-<ep>.yml` (optional) and `r2-uploads.log` (the uploaded file name).
- **Output:** `YYYY-MM-DD-<ep>.md`, copied to `$COWSAY_SOURCE`. It contains:
  - front matter with the title (`'` doubled for YAML), date, `duration` (from `ffprobe`), `audio: mp3` (the current R2 name, for example `cow173-rev1.mp3`), `filesize` (from `stat -f%z`) and **`chapters`**;
  - the Podigee player tag;
  - the header, the topics and the footer.

If a post for the episode already exists in `_posts`, possibly from an earlier date, it's regenerated in place with its original file name and date, so there's never a second post for the same episode.

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
| 3 | Start the local server, wait for it, open the preview, then stop the server | `bundle exec octopod s &`, `open`, `kill` |
| 4 | Ask `y/[n]`. Any answer other than `y` exits | `read` |
| 5 | Build the site into `$SITE_DIR` | `bundle exec octopod b` |
| 6 | Deploy: commit and push `_site` to `$SITE_REPO`, which Cloudflare Pages deploys | `git -C $SITE_DIR add -A`, `commit`, `push` |
| 7 | Open the live site, then commit and push the site sources | `open`, `git add .`, `commit`, `push` |

`set -m` (job control) is on. `set -x` is on only with `-v`.

### 5.11 `trello.sh`: topic export

**Usage**

```bash
./trello.sh '<List Name>' <episode_number>
```

It finds the list on board `KOfBQFVg` by name, fetches its cards and their attachment URLs, and writes `trello_cards_<ep>.ssv` with lines of the form `<card name>†<url1;url2;…>`. Auth comes from `API_KEY` and `TOKEN` in `secrets.sh`.

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
| `trello_cards_<ep>.ssv` | `trello.sh` | `topics.sh` |
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
| 3 | Topic starts are the moment a topic is *introduced*, as Claude reads it | When the hosts lead into a topic for a while before naming it, the time can fall about 20 s either side of where a human would put the mark. Check the review step and press `e` to adjust |

---

### Don't forget to have fun ;) 🐮
