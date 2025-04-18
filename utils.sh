#!/bin/zsh

prepare_dir() {
    EPISODE_DIR=""$COWSAY_DIR"/$1"

    if [ ! -d "$EPISODE_DIR" ]; then
        mkdir -p "$EPISODE_DIR"
    fi
    cd "$EPISODE_DIR"
}