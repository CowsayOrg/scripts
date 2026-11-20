#!/bin/zsh

# Starts the Trello MCP server for Claude Code (.mcp.json) with the credentials from secrets.sh,
# so no secret lives in the committed config.

. "${0:A:h}/secrets.sh"

export TRELLO_API_KEY="$TRELLO_MCP_API_KEY"
export TRELLO_TOKEN="$TRELLO_MCP_TOKEN"
export TRELLO_BOARD_ID="KOfBQFVg"

exec node /Users/user/Code/Cowsay/mcp-server-trello/build/index.js
