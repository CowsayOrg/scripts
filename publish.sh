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
# set -x
# set -m

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
print_message "Add Github and Azure certificates"
cd ~/.ssh
ssh-add "$GITHUB_CERT_PATH" > "$LOG" 2>&1
ssh-add "$AZURE_CERT_PATH" > "$LOG" 2>&1

# Go to cowsay source

cd "$COWSAY_SOURCE"
cd ..

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
    exit 0
elif [ "$ANSWER" = "y" ]; then
    bundle exec octopod b > "$LOG" 2>&1
    bundle exec octopod deploy > "$LOG" 2>&1
else
    print_error "Not using this variant, please run the script again"
    exit 0
fi

print_success "Site is successfully deployed 🐮"

open "$PUBLIC_ADDRESS"

# Update repo

git add . > "$LOG" 2>&1
git commit -m "Episode $1" > "$LOG" 2>&1
git push > "$LOG" 2>&1

print_success "The new episode is pushed to Github 🐮"