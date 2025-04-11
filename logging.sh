#!/bin/zsh

prepare_logging() {
    DATE=$(date +"%Y-%m-%d-%M-%S")
    if [ ! -d .logs ]; then
        mkdir .logs
    fi
    cd .logs
    touch "$1-"$DATE".log"
    LOG=$(realpath "$1-"$DATE".log")
}

