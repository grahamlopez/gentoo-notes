#!/bin/bash
set -euo pipefail

REPO="<your-remote-url>"
GIT_DIR="/root/.sysfiles"
BRANCH="${1:-$(hostname)}"

git clone --bare "$REPO" "$GIT_DIR"

_sys() { git --git-dir="$GIT_DIR" --work-tree=/ "$@"; }

_sys config --local status.showUntrackedFiles no

# Back up conflicts, then checkout
if ! _sys checkout "$BRANCH" 2>/dev/null; then
    _sys checkout "$BRANCH" 2>&1 | grep "^\t" | awk '{print $1}' | \
        while read -r f; do
            mkdir -p "$GIT_DIR-backup/$(dirname "$f")"
            mv "/$f" "$GIT_DIR-backup/$f"
        done
    _sys checkout "$BRANCH"
fi

echo "Checked out branch '$BRANCH'. Conflicts backed up to ${GIT_DIR}-backup/"

