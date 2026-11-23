#!/bin/zsh

# Headless mode (COWSAY_HEADLESS=1): no browser, Quick Look, text editor or clipboard, no colors,
# and no prompts. Each review gate passes only if its name is in COWSAY_APPROVE (comma or space
# separated: cut, topics, site, youtube, backfill, all). Otherwise the script prints what is to be
# reviewed and exits with NEEDS_REVIEW (3), the same code as a declined review.
NEEDS_REVIEW=3
CUT_PENDING=4    # audio.sh -p: the cut review is deferred to episode.sh, nothing was built

headless() {
    [ "${COWSAY_HEADLESS:-}" = 1 ]
}

print_error() {
    if headless; then echo "ERROR: $1"; else echo -e "\033[31;40m$1\033[0m"; fi
}

print_message() {
    if headless; then echo "$1"; else echo -e "\033[34;40m$1\033[0m"; fi
}

print_success() {
    if headless; then echo "OK: $1"; else echo -e "\033[32;40m$1\033[0m"; fi
}

# approved <gate>: true if the gate was approved for this headless run
approved() {
    local list=" ${${COWSAY_APPROVE:-}//,/ } "
    [[ "$list" == *" $1 "* || "$list" == *" all "* ]]
}

# gate <name> <what to do>: in headless mode, continue if approved, otherwise stop for review
gate() {
    approved "$1" && return 0
    echo "NEEDS_REVIEW: $1 ($2). Rerun with COWSAY_APPROVE including \"$1\" to continue."
    exit $NEEDS_REVIEW
}

# ui_open <args for open>: open a page or file, except in headless mode
ui_open() {
    if headless; then
        echo "(headless, not opening: ${@[-1]})"
    else
        open "$@"
    fi
}
