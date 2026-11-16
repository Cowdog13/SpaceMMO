#!/usr/bin/env bash
# Run the dedicated SpaceMMO server headless.
#   GODOT=/path/to/godot ./run_server.sh [--port 7777] [--data ./server_data] [--dev]
set -e
cd "$(dirname "$0")"
GODOT="${GODOT:-godot}"
if [ ! -d .godot ]; then
  echo "First run: importing project..."
  "$GODOT" --headless --path . --import || true
fi
exec "$GODOT" --headless --path . -- --server --data ./server_data "$@"
