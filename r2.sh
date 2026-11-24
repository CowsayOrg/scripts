#!/bin/zsh

# Cloudflare R2 helpers (sourced by audio.sh, template-md.sh and r2-uploads.sh).
#
# The bucket has an object lock: an uploaded object can't be deleted or replaced until the
# lock expires. So a fixed episode audio is uploaded under a new name:
#   cow<ep>.mp3, then cow<ep>-rev1.mp3, cow<ep>-rev2.mp3, ...
# and every upload is written to $R2_UPLOAD_LOG, so the old revisions can be deleted later
# with ./r2-uploads.sh cleanup.
#
# Log format (tab separated, append only):
#   <date UTC ISO 8601>  <action>  <episode>  <object name>  <md5 or ->
# actions: uploaded (by these scripts), found (already in the bucket before the log existed),
#          deleted (removed by r2-uploads.sh cleanup)

R2_UPLOAD_LOG="${R2_UPLOAD_LOG:-$COWSAY_DIR/r2-uploads.log}"

# r2_log <action> <episode> <name> <md5> [date]
r2_log() {
    local date="${5:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    print -r -- "$date"$'\t'"$1"$'\t'"$2"$'\t'"$3"$'\t'"$4" >> "$R2_UPLOAD_LOG"
}

# r2_logged <name>: true if the name appears in the log at all
r2_logged() {
    [ -f "$R2_UPLOAD_LOG" ] && awk -F'\t' -v n="$1" '$4 == n { found = 1 } END { exit !found }' "$R2_UPLOAD_LOG"
}

# r2_current_name <episode>: the latest uploaded (or found) object name of the episode, empty if none
r2_current_name() {
    [ -f "$R2_UPLOAD_LOG" ] || return 0
    awk -F'\t' -v ep="$1" '$3 == ep && ($2 == "uploaded" || $2 == "found") { name = $4 } END { if (name) print name }' "$R2_UPLOAD_LOG"
}

# r2_audio_name <episode>: object name the post must reference (cow<ep>.mp3 if nothing was uploaded yet)
r2_audio_name() {
    local name
    name=$(r2_current_name "$1")
    print -r -- "${name:-cow$1.mp3}"
}

# r2_head <name>: prints "<etag>\t<last-modified ISO>" if the object is public (HTTP 200), nothing otherwise
r2_head() {
    local headers code etag modified
    headers=$(curl -s -I "$PUBLIC_AUDIO_URL/$1") || return 0
    code=$(print -r -- "$headers" | awk 'NR == 1 { print $2 }')
    [ "$code" = "200" ] || return 0
    etag=$(print -r -- "$headers" | awk -F': ' 'tolower($1) == "etag" { gsub(/[\r"]/, "", $2); print $2 }')
    modified=$(print -r -- "$headers" | awk -F': ' 'tolower($1) == "last-modified" { sub(/\r/, "", $2); print $2 }')
    modified=$(date -j -u -f "%a, %d %b %Y %H:%M:%S GMT" "$modified" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
    print -r -- "$etag"$'\t'"$modified"
}

# r2_choose_name <episode> <md5>: prints "same <name>" if that audio is already uploaded,
# or "new <name>" with the first free name (cow<ep>.mp3, cow<ep>-rev1.mp3, ...).
# Objects found in the bucket that are not in the log yet are added to it as "found".
r2_choose_name() {
    local ep="$1" md5="$2" rev name head etag modified
    for rev in {0..99}; do
        if [ "$rev" = 0 ]; then name="cow$ep.mp3"; else name="cow$ep-rev$rev.mp3"; fi
        head=$(r2_head "$name")
        etag="${head%%$'\t'*}"
        modified="${head#*$'\t'}"
        if [ -n "$head" ] && [ "$etag" = "$md5" ]; then
            r2_logged "$name" || r2_log found "$ep" "$name" "$etag" "${modified:-}"
            print -r -- "same $name"
            return 0
        elif [ -n "$head" ]; then
            r2_logged "$name" || r2_log found "$ep" "$name" "${etag:--}" "${modified:-}"
        elif ! r2_logged "$name"; then
            print -r -- "new $name"
            return 0
        fi
    done
    print_error "No free object name for episode $ep (tried up to rev99)"
    return 1
}

# post_duration <mp3>: H:MM:SS as used in the post front matter
post_duration() {
    local d
    d=$(ffprobe -i "$1" -show_entries format=duration -v quiet -of csv="p=0" -sexagesimal)
    print -r -- "${d:0:-7}"
}

# find_post <episode>: path of the episode post in $COWSAY_SOURCE, empty if there is none
find_post() {
    local posts=("$COWSAY_SOURCE"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-$1.md(N))
    [ ${#posts} -gt 0 ] && print -r -- "${posts[-1]}"
    return 0
}

# patch_post_audio <post> <name> <size> <duration>: point an existing post to a new audio file
patch_post_audio() {
    local tmp="$1.tmp"
    awk -v name="$2" -v size="$3" -v dur="$4" '
        /^---/ { fm++ }
        fm == 1 && /^[^ ]/ { parent = $1 }
        fm == 1 && parent == "audio:" && /^  mp3:/ { print "  mp3: " name; next }
        fm == 1 && parent == "filesize:" && /^  mp3:/ { print "  mp3: " size; next }
        fm == 1 && /^duration:/ { print "duration: '\''" dur "'\''"; next }
        { print }
    ' "$1" > "$tmp" && mv "$tmp" "$1"
}

# patch_post_chapters <post> <chapters.yml>: replace the post's chapter marks with the file's
patch_post_chapters() {
    local tmp="$1.tmp"
    awk -v cf="$2" '
        /^---/ { fm++; skip = 0 }
        skip && /^  - / { next }
        { skip = 0 }
        fm == 1 && /^chapters:/ { print "chapters:"; while ((getline l < cf) > 0) print l; skip = 1; next }
        { print }
    ' "$1" > "$tmp" && mv "$tmp" "$1"
}
