#!/bin/bash
# Packs titi (scripts/package.sh) and (re)starts dist/Titi.app in the background. Log: ~/Library/Logs/titi.log
# TITI_FAST=1 scripts/run.sh  -> focus timer runs 20x faster, for trying it out.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/package.sh
pkill -x Titi 2>/dev/null || true
pkill -x Clomodoro 2>/dev/null || true   # the old name
# the binary inside the bundle, so it reads the same settings as the app opened from Finder
nohup dist/Titi.app/Contents/MacOS/Titi >> "$HOME/Library/Logs/titi.log" 2>&1 &
disown
echo "titi running (pid $!). Log: ~/Library/Logs/titi.log"
