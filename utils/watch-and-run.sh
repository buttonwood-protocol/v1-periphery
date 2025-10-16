#!/bin/bash

# Directory to watch (defaults to current directory)
WATCH_DIR="${1:-.}"
# Shift off the directory, remaining args are the command
shift
CMD="$@"

# Check that a command was provided
if [ -z "$CMD" ]; then
  echo "Usage: $0 [directory] command_to_run"
  exit 1
fi

# Check for fswatch
if ! command -v fswatch >/dev/null 2>&1; then
  echo "Error: fswatch is not installed. Install it with: brew install fswatch"
  exit 2
fi

echo "Watching directory: $WATCH_DIR"
echo "Running command: $CMD"

# Debounce time to avoid repeated triggers (in seconds)
DEBOUNCE_DELAY=0.5

run_cmd() {
  clear
  echo "Change detected. Running command..."
  eval "$CMD"
  echo "Watching for further changes..."
}

# Initial run
run_cmd

# Watch for file changes
fswatch -0 "$WATCH_DIR" | while IFS= read -r -d "" file; do
  sleep "$DEBOUNCE_DELAY"
  run_cmd
done
