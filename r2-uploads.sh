#!/bin/zsh

# Inspect the R2 upload log and delete superseded episode audio files.
#
# Usage:
#   ./r2-uploads.sh list [<episode>]        show the uploads and which file each episode uses
#   ./r2-uploads.sh cleanup [-n] [-v]       delete the old revisions (-n: dry run, only show them)
#
# A file is deleted only if it is not the episode's current file (the latest upload) and no post
# in $COWSAY_SOURCE references it. Files still under the bucket's object lock are reported and
# kept; run cleanup again later. The current file keeps its -rev<n> name, nothing is renamed.

SCRIPTS_DIR="${0:A:h}"
cd "$SCRIPTS_DIR"

. ./messages.sh
. ./logging.sh
. ./vars.sh
. ./r2.sh

set -euo pipefail

usage() {
    echo "Usage: $0 list [<episode>] | cleanup [-n] [-v]" >&2
    exit 1
}

# Names still in the bucket (uploaded or found, not deleted), as "<episode>\t<name>\t<date>\t<current>"
live_objects() {
    awk -F'\t' '
        $2 == "uploaded" || $2 == "found" { if (!($4 in date)) order[++n] = $4; ep[$4] = $3; date[$4] = $1; cur[$3] = $4; gone[$4] = 0 }
        $2 == "deleted" { gone[$4] = 1 }
        END { for (i = 1; i <= n; i++) { k = order[i]; if (!gone[k]) print ep[k] "\t" k "\t" date[k] "\t" (cur[ep[k]] == k ? "current" : "old") } }
    ' "$R2_UPLOAD_LOG"
}

list() {
    local filter="${1:-}"
    print "Upload log: $R2_UPLOAD_LOG"
    print ""
    printf "%-8s %-24s %-22s %s\n" EPISODE FILE "UPLOADED (UTC)" STATE
    live_objects | while IFS=$'\t' read -r ep name date state; do
        [ -z "$filter" ] || [ "$ep" = "$filter" ] || continue
        printf "%-8s %-24s %-22s %s\n" "$ep" "$name" "${date:-unknown}" "$state"
    done
}

cleanup() {
    local dry=false out kept=0 deleted=0 locked=0
    while getopts ":nv" opt; do
        case ${opt} in
            n ) dry=true ;;
            v ) set -x ;;
            * ) usage ;;
        esac
    done

    prepare_logging "r2-cleanup"

    live_objects | while IFS=$'\t' read -r ep name date state; do
        [ "$state" = "old" ] || continue

        if grep -rqx "  mp3: $name" "$COWSAY_SOURCE" 2>/dev/null; then
            print_error "$name (episode $ep) is still referenced by a post, keeping it"
            kept=$((kept + 1))
            continue
        fi

        if [ "$dry" = true ]; then
            print_message "Would delete $name (episode $ep, uploaded ${date:-at an unknown date})"
            continue
        fi

        if out=$(rclone deletefile "$R2_REMOTE:$R2_BUCKET/$name" --retries 1 2>&1); then
            r2_log deleted "$ep" "$name" -
            print_success "Deleted $name (episode $ep)"
            deleted=$((deleted + 1))
        elif [[ "$out" == *ObjectLocked* ]]; then
            print_message "$name (episode $ep, uploaded ${date:-at an unknown date}) is still locked, try again later"
            locked=$((locked + 1))
        else
            print -r -- "$out" >> "$LOG"
            print_error "Could not delete $name, see $LOG"
            kept=$((kept + 1))
        fi
    done

    [ "$dry" = true ] || print_message "Deleted: $deleted, still locked: $locked, kept: $kept"
}

[ $# -ge 1 ] || usage
if [ ! -f "$R2_UPLOAD_LOG" ]; then
    print_message "No uploads logged yet ($R2_UPLOAD_LOG)"
    exit 0
fi

case "$1" in
    list )    shift; list "$@" ;;
    cleanup ) shift; cleanup "$@" ;;
    * )       usage ;;
esac
