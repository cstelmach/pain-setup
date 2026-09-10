#!/bin/bash
# File attribution
# created by Christian Stelmach (chrisp.stel@gmail.com), GitHub: @cstelmach
"$(cd "$(dirname "$0")" && pwd)/export-interactions.sh" "$@"
STATUS=$?
read -r -p 'Press Enter to close.'
exit "$STATUS"
