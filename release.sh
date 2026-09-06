#!/bin/bash
set -euo pipefail

# Usage: ./release.sh [major|minor|patch]
# Defaults to patch bump if no argument given.

bump="${1:-patch}"

# Get the latest tag
latest_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")
version=${latest_tag#v}
IFS='.' read -r major minor patch <<< "$version"

case "$bump" in
  major)
    major=$((major + 1))
    minor=0
    patch=0
    ;;
  minor)
    minor=$((minor + 1))
    patch=0
    ;;
  patch)
    patch=$((patch + 1))
    ;;
  *)
    echo "Usage: $0 [major|minor|patch]"
    exit 1
    ;;
esac

new_tag="v${major}.${minor}.${patch}"

echo "Current version: ${latest_tag}"
echo "New version:     ${new_tag}"
echo ""
read -p "Create and push tag ${new_tag}? [y/N] " confirm

if [[ "$confirm" != [yY] ]]; then
  echo "Aborted."
  exit 0
fi

git tag "$new_tag"
git push origin "$new_tag"

echo ""
echo "Tag ${new_tag} pushed. Release workflow will run automatically."
echo "Watch progress: gh run watch"
