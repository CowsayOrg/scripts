#!/bin/zsh

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title cow trello
# @raycast.mode fullOutput

# Optional parameters:
# @raycast.icon 📝
# @raycast.argument1 { "type": "text", "placeholder": "List Name" }
# @raycast.argument2 { "type": "text", "placeholder": "Episode Number" }
# @raycast.packageName cowsay-audio
# @raycast.needsConfirmation true

# Documentation:
# @raycast.description download audio from youtube
# @raycast.author vladd
# @raycast.authorURL https://raycast.com/vladd

. ./messages.sh
. ./vars.sh
. ./secrets.sh

print_message "Preparing the script and starting fetching the cards"

set -euo pipefail
# set -x

# Set your Trello credentials
BOARD_ID="KOfBQFVg"

# Output CSV file
OUTPUT_FILE="trello_cards_$2.ssv"

EPISODE_DIR=""$COWSAY_DIR"$2"

if [ ! -d "$EPISODE_DIR" ]; then
    mkdir -p "$EPISODE_DIR" > "$LOG" 2>&1
fi
cd "$EPISODE_DIR" > "$LOG" 2>&1

# Base API URL
BASE_URL="https://api.trello.com/1"

# Fetch all lists in the board
LISTS_URL="$BASE_URL/boards/$BOARD_ID/lists?key=$API_KEY&token=$TOKEN"
lists_response=$(curl -s "$LISTS_URL")

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    print_error "jq is not installed. Please install it to continue"
    exit 1
fi

# Find the list ID by name
LIST_ID=$(echo "$lists_response" | jq -r --arg LIST_NAME "$1" '.[] | select(.name == $LIST_NAME) | .id')

if [ -z "$LIST_ID" ]; then
    print_error "Error: List '$1' not found in the board"
    exit 1
fi

print_message "Found List: $1 (ID: $LIST_ID)"

# Fetch all cards in the list
CARDS_URL="$BASE_URL/lists/$LIST_ID/cards?key=$API_KEY&token=$TOKEN"
cards_response=$(curl -s "$CARDS_URL")

# Process each card to fetch its attachments
echo "$cards_response" | jq -c '.[]' | while read -r card; do
    # Get card name and ID
    card_name=$(echo "$card" | jq -r '.name')
    card_id=$(echo "$card" | jq -r '.id')

    # Fetch attachments for the card
    ATTACHMENTS_URL="$BASE_URL/cards/$card_id/attachments?key=$API_KEY&token=$TOKEN"
    attachments_response=$(curl -s "$ATTACHMENTS_URL")


    # Extract attachment URLs
    attachment_urls=$(echo "$attachments_response" | jq -r 'map(.url) | join(";")')

    # Write to CSV
    echo ""$card_name"†"$attachment_urls"" >> "$OUTPUT_FILE"
done

print_success "Export complete! File saved as $OUTPUT_FILE"
