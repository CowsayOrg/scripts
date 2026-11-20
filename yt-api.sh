#!/bin/zsh

# YouTube Data API v3 helpers (sourced by youtube-update.sh and youtube-backfill.sh).
#
# Auth: OAuth 2.0 for an installed app. youtube-auth.sh does the one-time browser login and writes
# $YT_TOKEN_FILE with a refresh token; here it is exchanged for short-lived access tokens.
# Quota (10,000 units a day): list calls 1, videos.update/playlistItems.insert 50, captions.insert 400.

YT_API="https://www.googleapis.com/youtube/v3"
YT_UPLOAD_API="https://www.googleapis.com/upload/youtube/v3"
YT_OAUTH_TOKEN_URL="https://oauth2.googleapis.com/token"
YT_SCOPE="https://www.googleapis.com/auth/youtube.force-ssl"   # read/write videos, playlists, captions

# yt_configured: true if the client and the token exist (the one-time setup was done)
yt_configured() {
    [ -s "$YT_CLIENT_FILE" ] && [ -s "$YT_TOKEN_FILE" ]
}

yt_client_field() {
    jq -r --arg f "$1" '(.installed // .web)[$f] // empty' "$YT_CLIENT_FILE"
}

# yt_access_token: prints a valid access token, refreshing it when it is about to expire
yt_access_token() {
    local now expires response
    now=$(date +%s)
    expires=$(jq -r '.expires_at // 0' "$YT_TOKEN_FILE")
    if (( expires - 60 > now )); then
        jq -r '.access_token' "$YT_TOKEN_FILE"
        return 0
    fi

    response=$(curl -s -X POST "$YT_OAUTH_TOKEN_URL" \
        --data-urlencode "client_id=$(yt_client_field client_id)" \
        --data-urlencode "client_secret=$(yt_client_field client_secret)" \
        --data-urlencode "refresh_token=$(jq -r '.refresh_token' "$YT_TOKEN_FILE")" \
        --data-urlencode "grant_type=refresh_token")
    if [ -z "$(jq -r '.access_token // empty' <<< "$response")" ]; then
        print_error "Could not refresh the YouTube token: $(jq -r '.error_description // .error // .' <<< "$response")" >&2
        print_error "Run ./youtube-auth.sh again" >&2
        return 1
    fi
    jq --argjson r "$response" --argjson now "$now" \
        '.access_token = $r.access_token | .expires_at = ($now + $r.expires_in)' "$YT_TOKEN_FILE" > "$YT_TOKEN_FILE.tmp"
    mv "$YT_TOKEN_FILE.tmp" "$YT_TOKEN_FILE"
    chmod 600 "$YT_TOKEN_FILE"
    jq -r '.access_token' "$YT_TOKEN_FILE"
}

# yt_api <METHOD> <url> [curl args...]: calls the API, prints the response body, fails on HTTP errors
yt_api() {
    local method="$1" url="$2" token body code
    shift 2
    local attempt
    token=$(yt_access_token) || return 1
    for attempt in 1 2 3 4; do
        body=$(curl -s -w $'\n%{http_code}' -X "$method" "$url" -H "Authorization: Bearer $token" "$@")
        code="${body##*$'\n'}"
        body="${body%$'\n'*}"
        [[ "$code" == 5* || "$code" == 000 ]] || break    # retry server errors, they are usually transient
        (( attempt < 4 )) && { print_message "YouTube API answered HTTP $code, retrying in $(( attempt * 5 )) s" >&2; sleep $(( attempt * 5 )); }
    done
    if [[ "$code" != 2* ]]; then
        print_error "YouTube API $method ${url%%\?*} failed (HTTP $code): $(jq -r '.error.message // .' <<< "$body" 2>/dev/null || print -r -- "$body")" >&2
        print -r -- "$body" >> "${LOG:-/dev/null}"
        return 1
    fi
    print -r -- "$body"
}

# yt_api_json <METHOD> <url> <json>: same with a JSON body
yt_api_json() {
    yt_api "$1" "$2" -H "Content-Type: application/json" --data-binary "$3"
}

# yt_video <id>: prints the video resource with snippet and status
yt_video() {
    local r
    r=$(yt_api GET "$YT_API/videos?part=snippet,status&id=$1") || return 1
    jq '.items[0] // empty' <<< "$r"
}

# yt_in_playlist <playlist> <video>: true if the video is already in the playlist
yt_in_playlist() {
    local n
    local r
    r=$(yt_api GET "$YT_API/playlistItems?part=id&maxResults=1&playlistId=$1&videoId=$2") || return 2
    n=$(jq '.items | length' <<< "$r")
    (( n > 0 ))
}

# yt_add_to_playlist <playlist> <video>
yt_add_to_playlist() {
    yt_api_json POST "$YT_API/playlistItems?part=snippet" \
        "$(jq -n --arg p "$1" --arg v "$2" '{ snippet: { playlistId: $p, resourceId: { kind: "youtube#video", videoId: $v } } }')" > /dev/null
}

# yt_caption_id <video> <name>: id of our caption track, empty if there is none
yt_caption_id() {
    local r
    r=$(yt_api GET "$YT_API/captions?part=snippet&videoId=$1") || return 1
    jq -r --arg n "$2" '[ .items[] | select(.snippet.name == $n) ] | first | .id // empty' <<< "$r"
}

# yt_upload_caption <video> <srt file> [<existing caption id>]: inserts a track, or replaces an existing one
yt_upload_caption() {
    local video="$1" srt="$2" existing="${3:-}" boundary="cowsay$RANDOM$RANDOM" body method url meta
    body=$(mktemp)
    if [ -n "$existing" ]; then
        method=PUT
        url="$YT_UPLOAD_API/captions?uploadType=multipart&part=snippet"
        meta=$(jq -n --arg id "$existing" '{ id: $id, snippet: { isDraft: false } }')
    else
        method=POST
        url="$YT_UPLOAD_API/captions?uploadType=multipart&part=snippet"
        meta=$(jq -n --arg v "$video" --arg l "$YT_LANGUAGE" --arg n "$YT_CAPTION_NAME" \
            '{ snippet: { videoId: $v, language: $l, name: $n, isDraft: false } }')
    fi
    {
        printf -- '--%s\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n%s\r\n' "$boundary" "$meta"
        printf -- '--%s\r\nContent-Type: application/octet-stream\r\n\r\n' "$boundary"
        cat "$srt"
        printf -- '\r\n--%s--\r\n' "$boundary"
    } > "$body"
    yt_api "$method" "$url" -H "Content-Type: multipart/related; boundary=$boundary" --data-binary "@$body" > /dev/null
    local result=$?
    rm -f "$body"
    return $result
}
