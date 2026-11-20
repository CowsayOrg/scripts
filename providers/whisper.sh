#!/bin/zsh

# Local Whisper adapter (placeholder, not implemented yet).
# To use a local model, implement provider_transcribe below and set TRANSCRIBE_PROVIDER="whisper" in vars.sh.
#
# Sketch with whisper.cpp (brew install whisper-cpp, plus a downloaded ggml model):
#   whisper-cli -m "$WHISPER_MODEL" -l ro -ojf -of "${out:r}.provider" -f <16 kHz wav of $in>
# then convert its JSON to the normalized contract (providers/README.md) with jq.

provider_transcribe() {
    print_error "The whisper provider is not implemented yet (providers/whisper.sh)"
    return 1
}
