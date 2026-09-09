#!/bin/bash
"$(cd "$(dirname "$0")" && pwd)/export-interactions.sh" "$@"
STATUS=$?
read -r -p 'Press Enter to close.'
exit "$STATUS"
