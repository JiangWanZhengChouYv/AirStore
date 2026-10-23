#!/bin/bash
# Double-click this in Finder: Terminal opens and shows every CI run in flight.
# Same script as the `ciw` shell alias, so the two can never disagree.
cd "$(dirname "$0")/.." || exit 1
exec ./scripts/ci-watch.sh "$@"
