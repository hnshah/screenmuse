#!/bin/bash
# auto_record_skill.sh — Record any OpenClaw skill execution end-to-end.
#
# Usage: ./auto_record_skill.sh <skill-name> <command...>
# Example: ./auto_record_skill.sh "typeahead-blog-post" python3 my_skill.py

set -euo pipefail

SKILL_NAME="${1:-unnamed-skill}"
shift

HELPER="$(dirname "$0")/screenmuse_helper.py"

# Start recording
python3 "$HELPER" start "$SKILL_NAME" > /dev/null 2>&1

# Run the actual command
set +e
"$@"
EXIT_CODE=$?
set -e

# Mark result as chapter
if [ $EXIT_CODE -eq 0 ]; then
    python3 "$HELPER" chapter "Completed successfully" > /dev/null 2>&1
else
    python3 "$HELPER" chapter "Failed (exit $EXIT_CODE)" > /dev/null 2>&1
fi

# Stop recording
RESULT=$(python3 "$HELPER" stop 2>/dev/null)
VIDEO_PATH=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('video_path',''))" 2>/dev/null)

if [ -n "$VIDEO_PATH" ]; then
    echo "Recording saved: $VIDEO_PATH"
fi

exit $EXIT_CODE
