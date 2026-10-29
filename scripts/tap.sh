#!/bin/sh
# tap.sh VERSION: publishes homebrew/macstats.rb to csarkosh/homebrew-tap as Casks/macstats.rb, so
# `brew install --cask csarkosh/tap/macstats` installs the latest release. The release workflow
# runs it after `gh release create`, since the cask points at the release's zip, with the
# HOMEBREW_TAP_DEPLOY_KEY deploy key in GIT_SSH_COMMAND; from a Mac it uses that Mac's own git
# access. DRY_RUN=1 shows the change and pushes nothing. Safe to run again: a cask the tap already
# has is not committed. (The formula, Formula/macstats.rb, is still bumped by hand: AGENTS.md.)
set -eu
cd "$(dirname "$0")/.."
VERSION="${1:?usage: scripts/tap.sh VERSION}"
grep -q "^  version \"$VERSION\"\$" homebrew/macstats.rb ||
  { echo "tap.sh: homebrew/macstats.rb is not at $VERSION (cask.sh records a release)" >&2; exit 1; }
TAP=$(mktemp -d)
trap 'rm -rf "$TAP"' EXIT
git clone -q --depth 1 "${TAP_REMOTE:-git@github.com:csarkosh/homebrew-tap.git}" "$TAP"
cp homebrew/macstats.rb "$TAP/Casks/macstats.rb"
cd "$TAP"
if git diff --quiet; then
  echo "tap.sh: the tap already has the macstats $VERSION cask"
  exit 0
fi
git --no-pager diff
if [ "${DRY_RUN:-0}" = 1 ]; then
  echo "tap.sh: DRY_RUN, nothing pushed"
  exit 0
fi
# The release runner has no git identity of its own; a Mac's is used when it has one.
git config user.email > /dev/null || git config user.email "release@csarko.sh"
git config user.name > /dev/null || git config user.name "release workflow"
git commit -qam "macstats $VERSION (cask)"
# Other packages are released to the same tap; a push that lost the race rebases and tries again.
for TRY in 1 2 3; do
  if git push -q origin HEAD:main; then
    echo "tap.sh: published the macstats $VERSION cask"
    exit 0
  fi
  git pull -q --rebase origin main
done
echo "tap.sh: could not push to the tap" >&2
exit 1
