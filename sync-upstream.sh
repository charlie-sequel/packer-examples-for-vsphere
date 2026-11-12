#!/bin/bash
# Checks vmware/packer-examples-for-vsphere (develop branch) for updates and notifies you
# (macOS notification).
#
#   ./sync-upstream.sh            fetch upstream + notify if there are new commits
#   ./sync-upstream.sh --open-pr  also push a sync branch to origin and open a PR
#                                 (run from a terminal — needs your gh/SSH auth)
#
# The plain mode is what the scheduled LaunchAgent runs: it fetches the PUBLIC upstream
# over HTTPS (no auth, so it's reliable under launchd's bare environment) and never
# auto-merges. You review, then: git merge upstream/develop
set -uo pipefail

# launchd runs with a minimal PATH; make sure git/gh/osascript are found.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
UPSTREAM_URL="https://github.com/vmware/packer-examples-for-vsphere.git"
BR="automated/upstream-sync"
cd "$REPO_DIR" || exit 1

notify() { osascript -e "display notification \"$1\" with title \"SDS vSphere-lab sync\"" >/dev/null 2>&1; }

echo "=== $(date '+%Y-%m-%d %H:%M:%S') sync-upstream ==="

# Fetch upstream/develop over HTTPS (public repo -> no credentials needed).
if ! git fetch "$UPSTREAM_URL" 'refs/heads/develop:refs/remotes/upstream/develop'; then
  echo "ERROR: upstream fetch failed"; notify "Upstream fetch failed"; exit 1
fi

if git merge-base --is-ancestor upstream/develop main; then
  echo "Already up to date with upstream."
  exit 0
fi

COUNT="$(git rev-list --count main..upstream/develop)"
echo "$COUNT new upstream commit(s) available."

if [ "${1:-}" = "--open-pr" ]; then
  ORIGIN_REPO="$(git config --get remote.origin.url | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
  SHA="$(git rev-parse upstream/develop)"
  git push -f origin "$SHA:refs/heads/$BR" || { echo "push failed"; exit 1; }
  if [ -z "$(gh pr list -R "$ORIGIN_REPO" --head "$BR" --state open --json number -q '.[0].number' 2>/dev/null)" ]; then
    gh pr create -R "$ORIGIN_REPO" --base main --head "$BR" \
      --title "Sync upstream: vmware/packer-examples-for-vsphere@develop" \
      --body "Automated upstream sync ($COUNT new commit(s)). Review and merge; resolve conflicts if GitHub flags them."
    echo "PR opened."
  else
    echo "PR already open; branch refreshed."
  fi
  notify "$COUNT new upstream commit(s) — sync PR ready for review."
else
  notify "$COUNT new upstream commit(s). Review, then: git merge upstream/develop"
fi
