#!/usr/bin/env bash

# the directory where this shell script lives
SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"

# run the swift interpreter directly on the script file
swift "$SCRIPT_DIR/generate_wabi_headers.swift" "$@"
