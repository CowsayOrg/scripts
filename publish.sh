#!/bin/zsh

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title cow publish
# @raycast.mode fullOutput

# Optional parameters:
# @raycast.icon 🎼
# @raycast.argument1 { "type": "text", "placeholder": "Episode Number" }
# @raycast.packageName cowsay-audio
# @raycast.needsConfirmation true

# Documentation:
# @raycast.description download audio from youtube
# @raycast.author vladd
# @raycast.authorURL https://raycast.com/vladd

. ./messages.sh
. ./logging.sh
. ./vars.sh

set -euo pipefail
set -m

if [ "${2:-}" = "-v" ]; then
    set -x
fi

print_message "Preparing to execute the script"

# Check for episode number to be present
if [ -z "$1" ]; then
    print_error "This script needs episode number in order to work"
    exit 1
fi

# Prepare the logs
prepare_logging "publish"

# Check on OS
OS="$(uname -s)"

if [ $OS != "Darwin" ]; then
    print_error "This script is meant to be running on macOS"
    exit 1
fi

# Check for certificates to be there
print_message "Add Github certificate"
cd ~/.ssh
ssh-add "$GITHUB_CERT_PATH" > "$LOG" 2>&1

# Go to cowsay source

cd "$COWSAY_SOURCE"
cd ..

# _site must be a clone of the GitHub Pages repo that Cloudflare Pages deploys from
if ! git -C "$SITE_DIR" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    print_error "$SITE_DIR is not a git repository. Clone $SITE_REPO into it first"
    exit 1
fi

# Run server and open the page to check
print_message "Launching the server... openning the page"

bundle exec octopod s > "$LOG" 2>&1 &
PID=$!
until grep -q "Server address: "$LOCAL_ADDRESS"" "$LOG"; do
    sleep 1
done
open "$LOCAL_ADDRESS"
sleep 1
kill $PID

# Ask user to deploy this variant

print_message "Do you want to proceed with this variant? y/[n]"
read ANSWER

if [ -z "$ANSWER" ]; then
    print_error "Not using this variant, please run the script again"
    exit 3    # declined, see REVIEW_DECLINED in episode.sh
elif [ "$ANSWER" = "y" ]; then
    bundle exec octopod b > "$LOG" 2>&1
else
    print_error "Not using this variant, please run the script again"
    exit 3
fi

# Deploy: push the built site to GitHub, Cloudflare Pages picks it up from there

print_message "Pushing the built site to $SITE_REPO"

git -C "$SITE_DIR" add -A > "$LOG" 2>&1
if git -C "$SITE_DIR" diff --cached --quiet; then
    print_message "The built site has no changes, nothing to deploy"
else
    git -C "$SITE_DIR" commit -m "Episode $1" > "$LOG" 2>&1
    git -C "$SITE_DIR" push > "$LOG" 2>&1
fi

print_success "Site is pushed, Cloudflare Pages will deploy it shortly 🐮"

open "$PUBLIC_ADDRESS"

# Update source repo

git add . > "$LOG" 2>&1
if git diff --cached --quiet; then
    print_message "The site source has no changes to commit"
else
    git commit -m "Episode $1" > "$LOG" 2>&1
fi
git push > "$LOG" 2>&1

print_success "The new episode is pushed to Github 🐮"