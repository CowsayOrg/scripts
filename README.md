## Prerequisits
1. Check for requirements.txt and install missing utils.
2. Check for cowsay site source dir.
3. This script runs only on macOS because relies on some OS specific tools (pbcopy, qlmanage etc.)
4. Create secrets.sh file with the Trello credentials (for trello.sh) and the ElevenLabs API key (for the transcription). Like this:
```bash
#!/bin/zsh

API_KEY="1234"
TOKEN="123456789abc"
ELEVENLABS_API_KEY="sk_..."
```
5. Visit vars.sh and adjust path to your locations:
  * COWSAY_DIR: where you want to store all the working files, mp3's, csv's, txt's etc.
  * COVER: cowsay podcast cover image for adding meta to resulting file.
  * COWSAY_SOURCE: cowsay site sources location (its `_posts` dir).
  * SITE_DIR: the built site (`_site` inside the site sources). It must be a git clone of SITE_REPO.
  * SITE_REPO: GitHub repo the built site is pushed to. Cloudflare Pages deploys cowsay.show from it.
  * GITHUB_CERT_PATH: for pushing the site sources and the built site to Github.
  * LOCAL_ADDRESS: likely stays the same, for testing, local server.
  * PUBLIC_ADDRESS: also less probable to change, but who knows, cowsay show public site URL.
  * R2_REMOTE, R2_BUCKET, PUBLIC_AUDIO_URL: Cloudflare R2 rclone remote and bucket for the episode mp3s, and their public URL.
  * TRANSCRIBE_PROVIDER, TRANSCRIBE_LANGUAGE, ELEVENLABS_MODEL: speech-to-text settings (see providers/README.md).
  * LLM_MODEL: Claude Code model used for the intro and topic detection.
  * CUT_*: intro cut detection settings.
6. Clone the built site repo into `_site` once, so publish.sh can push to it:
```bash
git clone git@github.com:CowsayOrg/CowsayOrg.github.io.git /Users/user/Code/Cowsay/cowsay-source/_site
```
7. Configure the R2 remote once with `rclone config` (name `cowsay-episodes`, type s3, provider Cloudflare). The token needs Object Read & Write on the `cowsay-show-episodes` bucket. The bucket has an object lock, so an uploaded mp3 can't be deleted or replaced until the lock expires.

## Deploy
The site is deployed by Cloudflare Pages. publish.sh builds the site with `bundle exec octopod b`, then commits and pushes the contents of `_site` to SITE_REPO. Cloudflare Pages picks up the push and deploys it. The site sources are committed and pushed to their own repo afterwards. `octopod deploy` (rsync over ssh) is not used anymore.

Episode mp3s are uploaded to Cloudflare R2 (`audio.sh -u`) and served from https://episodes.cowsay.show.

Because of the bucket's object lock, a fixed audio for an episode is uploaded as `cow<ep>-rev1.mp3`, `-rev2`, and so on. The existing post is updated to point to it. Every upload is logged in `$COWSAY_DIR/r2-uploads.log`. Once the lock period has passed, delete the old revisions with:
```bash
./r2-uploads.sh cleanup -n   # dry run
./r2-uploads.sh cleanup
```

## How to use the scripts
1. Before the show, put the topics as cards in the show's Trello list (named after the date, e.g. "Nov 20"), with links as attachments or in the description. The scripts find the list by the stream date and take the links from it (trello.sh).
2. Run the show. Nothing to record by hand anymore. Optionally say "cut" on air right before the greeting, it makes the intro detection exact.
3. Use episode.sh to do the rest: transcribe the recording, detect the intro cut, crop/compress/tag the audio, upload it, place the Trello topics on the timeline, generate the show notes and chapters, publish. Follow the messages in the console, it asks you to confirm the audio cut, the topics and the site.
```bash
./episode.sh -e 666 -u     # one episode
./episode.sh -a -u         # every episode streamed on YouTube but not published on cowsay.show yet
```
The title comes from the YouTube stream. The recording is found in the episode folder or in ~/Downloads (as YouTube Studio names it), or downloaded from YouTube.

The transcription (ElevenLabs) is the only paid step. It's cached per audio file, so re-running never pays twice for the same recording.

For a free run, use YouTube's automatic captions instead (only when the audio is YouTube's own download): `TRANSCRIBE_PROVIDER=youtube ./episode.sh -e 666 -u`.

With Claude Code, ask it to publish an episode: the `cowsay-episode` skill runs the same pipeline headless (no browser, Quick Look or clipboard) and asks you at each review step in the chat. See "Headless mode" in WORKFLOW.md.

The skill lives in its own repo (`CowsayOrg/cowsay-episode-skill`, private), included as a submodule at `.claude/skills/cowsay-episode`. Claude Code loads it from there, with nothing to install. Clone with `git clone --recurse-submodules`, or in an existing clone run `git submodule update --init`. To get a newer version of the skill: `git submodule update --remote`, then commit the new pointer.

## YouTube
After publishing, `youtube-update.sh` sets the episode's YouTube description (with chapters and the link to the post), tags, category and language, adds it to the "Lives" playlist, and uploads our transcript as captions. It shows a diff and asks first. It needs a one-time Google setup, described in WORKFLOW.md under "YouTube API setup". Until then the step is skipped.
```bash
./youtube-update.sh -e 666 -n   # dry run
./youtube-backfill.sh -n        # episodes missing from the Lives playlist
./youtube-notes.sh -e 666 -n    # show notes for an already published episode (free, from the captions)
```

Ideas that were proposed but not built yet are in FUTURE.md.

## Logs
There is an implicit logging system that will safe everything into .logs dir. Cannot be turned or customized for the moment.

## Docs
See WORKFLOW.md for the full description of every step, file and flag.

List of available options for episode.sh:
  * -e <number>, episode number (this or -a mandatory)
  * -a, publish every unpublished episode (this or -e mandatory)
  * -n <text>, override the episode title (default: the YouTube stream title)
  * -l <path>, override the source recording, audio or video (default: found on disk)
  * -y <url>, download the audio from this url instead
  * -u, upload to R2
  * -t, test run: fast crop, no compression, no cleanup. For script testing purposes.
  * -r, rebuild files if this is not the first run for this episode (the transcription stays cached).
  * -v, verbose.

### Don't forget to have fun ;)
