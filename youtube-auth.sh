#!/bin/zsh

# One-time YouTube login: opens the browser, you sign in and pick the @cowsay channel, and the
# refresh token is saved to $YT_TOKEN_FILE (gitignored). Run again if the token stops working.
#
# Usage: ./youtube-auth.sh
#
# Needs $YT_CLIENT_FILE: an OAuth client of type "Desktop app" downloaded from Google Cloud Console
# (APIs & Services > Credentials), with the YouTube Data API v3 enabled in the same project.

SCRIPTS_DIR="${0:A:h}"
cd "$SCRIPTS_DIR"

. ./messages.sh
. ./vars.sh
. ./yt-api.sh

set -euo pipefail

if [ ! -s "$YT_CLIENT_FILE" ]; then
    print_error "$YT_CLIENT_FILE not found. Download the OAuth client JSON (type Desktop app) from Google Cloud Console and save it there"
    exit 1
fi

CLIENT_ID=$(yt_client_field client_id)
CLIENT_SECRET=$(yt_client_field client_secret)

# PKCE and a random local port for the redirect
VERIFIER=$(openssl rand -base64 48 | tr -d '=+/\n' | cut -c1-64)
CHALLENGE=$(printf %s "$VERIFIER" | openssl dgst -sha256 -binary | openssl base64 | tr '+/' '-_' | tr -d '=\n')
STATE=$(openssl rand -hex 16)
PORT=$(( 49152 + RANDOM % 16000 ))
REDIRECT="http://127.0.0.1:$PORT"

AUTH_URL="https://accounts.google.com/o/oauth2/v2/auth?$(python3 -I -c '
import sys, urllib.parse
print(urllib.parse.urlencode({
    "client_id": sys.argv[1], "redirect_uri": sys.argv[2], "response_type": "code",
    "scope": sys.argv[3], "access_type": "offline", "prompt": "consent",
    "code_challenge": sys.argv[4], "code_challenge_method": "S256", "state": sys.argv[5]}))
' "$CLIENT_ID" "$REDIRECT" "$YT_SCOPE" "$CHALLENGE" "$STATE")"

if headless; then
    print_message "Open this in a browser, sign in, choose the @cowsay channel, and allow access: $AUTH_URL"
else
    print_message "Opening the browser. Sign in, choose the @cowsay channel, and allow access."
    print_message "If it doesn't open, visit: $AUTH_URL"
    open "$AUTH_URL"
fi

# Wait for the redirect with the code (one request, then the server stops)
CODE=$(python3 -I -c '
import sys, urllib.parse, http.server
port, state = int(sys.argv[1]), sys.argv[2]
result = {}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        ok = q.get("state", [""])[0] == state and "code" in q
        if ok: result["code"] = q["code"][0]
        elif "error" in q or "code" in q: result["error"] = q.get("error", ["state mismatch"])[0]
        self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8"); self.end_headers()
        self.wfile.write(("Done, you can close this tab 🐮" if ok else "Login failed: " + q.get("error", ["unknown"])[0]).encode())
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", port), H)
while "code" not in result and "error" not in result:
    s.handle_request()    # other requests (favicon) are answered and ignored
if "error" in result: sys.exit(1)
print(result["code"])
' "$PORT" "$STATE") || { print_error "Login failed or was cancelled"; exit 1; }

RESPONSE=$(curl -s -X POST "$YT_OAUTH_TOKEN_URL" \
    --data-urlencode "client_id=$CLIENT_ID" \
    --data-urlencode "client_secret=$CLIENT_SECRET" \
    --data-urlencode "code=$CODE" \
    --data-urlencode "code_verifier=$VERIFIER" \
    --data-urlencode "redirect_uri=$REDIRECT" \
    --data-urlencode "grant_type=authorization_code")

if [ -z "$(jq -r '.refresh_token // empty' <<< "$RESPONSE")" ]; then
    print_error "No refresh token in Google's answer: $(jq -r '.error_description // .error // "unknown error"' <<< "$RESPONSE")"
    exit 1
fi

umask 077
jq --argjson now "$(date +%s)" '{ refresh_token, access_token, expires_at: ($now + .expires_in), scope }' <<< "$RESPONSE" > "$YT_TOKEN_FILE"
chmod 600 "$YT_TOKEN_FILE"

CHANNEL=$(yt_api GET "$YT_API/channels?part=snippet&mine=true" | jq -r '.items[0].snippet.title // "?"')
print_success "Logged in as the YouTube channel \"$CHANNEL\". Token saved to $YT_TOKEN_FILE 🐮"
if [[ "$CHANNEL" != *[Cc]owsay* ]]; then
    print_error "That doesn't look like the Cowsay channel. Run ./youtube-auth.sh again and pick the channel (brand account) when Google asks"
fi
