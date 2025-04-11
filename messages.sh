#!/bin/zsh

print_error() {
    echo -e "\033[31;40m$1\033[0m"
}

print_message() {
    echo -e "\033[34;40m$1\033[0m"
}

print_success() {
    echo -e "\033[32;40m$1\033[0m"
}