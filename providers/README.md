# Transcription providers

`transcribe.sh` sources `providers/$TRANSCRIBE_PROVIDER.sh` (set in `vars.sh`) and calls:

```zsh
provider_transcribe <audio_in> <normalized_json_out>
```

The function must return non-zero on failure. All variables from `vars.sh` and `secrets.sh`, and the `print_*` helpers, are available to it.

## Normalized transcript contract

```json
{
  "provider": "elevenlabs",
  "language": "ron",
  "segments": [
    {
      "start": 12.34,
      "end": 15.10,
      "text": "Salut tuturor și bine ați venit",
      "speaker": "speaker_0",
      "words": [ { "text": "Salut", "start": 12.34, "end": 12.70 } ]
    }
  ]
}
```

- Times are seconds from the start of the input audio.
- `segments` is required and must not be empty. Each segment needs `start`, `end` and `text`.
- `speaker` is optional.
- `words` is optional, but it makes intro-cut detection more precise.
- Keep segments short (one phrase or sentence). `transcript.sh` merges them into blocks of about 30 s for the LLM.

## Adding a provider

1. Create `providers/<name>.sh` that defines `provider_transcribe`.
2. Put any keys it needs in `secrets.sh`.
3. Set `TRANSCRIBE_PROVIDER="<name>"` in `vars.sh`, or for one run: `TRANSCRIBE_PROVIDER=<name> ./episode.sh ...`.

Available providers:

- `elevenlabs`: ElevenLabs Scribe.
- `youtube`: YouTube's automatic captions of the stream (free). Only for audio that is YouTube's own download, since the captions are on the video timeline.
- `whisper`: placeholder for a local model.
