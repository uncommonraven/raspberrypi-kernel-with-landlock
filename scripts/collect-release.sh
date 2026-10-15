#!/usr/bin/env bash
# Lay out the staged files of every target for one release. Each target gets
# its own folder, so names such as modules.tar.gz and manifest.json do not
# collide. Each manifest is checked against its files before anything is copied.
#
# Usage: scripts/collect-release.sh <dest-dir> <target>=<release-dir>...
#   dest-dir     receives <target>/<file>; existing folders for the targets
#                given are replaced
#   target       folder name, e.g. bcm2712 or bcm2711
#   release-dir  staged output of scripts/build.sh, e.g. build/bcm2712/release
set -euo pipefail

die() {
  echo "collect-release: $*" >&2
  exit 1
}

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <dest-dir> <target>=<release-dir>..." >&2
  exit 2
fi
dest=$1
shift

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for arg in "$@"; do
  target=${arg%%=*}
  src=${arg#*=}
  [ "$src" != "$arg" ] || die "expected <target>=<release-dir>, got: $arg"
  case $target in
    ''|*[!A-Za-z0-9_-]*) die "target name must be letters, digits, '-' or '_': $target" ;;
  esac
  [ -f "$src/manifest.json" ] || die "$src has no manifest.json"

  # Entries in the "files" block look like: "<name>": "<sha256>"
  sed -n '/^  "files": {/,/^  }/s/^    "\([^"]*\)": "\([0-9a-f]\{64\}\)",\{0,1\}$/\2  \1/p' "$src/manifest.json" > "$tmp/$target.sha256"
  [ -s "$tmp/$target.sha256" ] || die "$src/manifest.json lists no files"
  (cd "$src" && sha256sum -c --quiet "$tmp/$target.sha256") \
    || die "$src does not match its manifest.json"

  rm -rf "$dest/$target"
  mkdir -p "$dest/$target"
  cp "$src/manifest.json" "$dest/$target/"
  awk '{ print $2 }' "$tmp/$target.sha256" | while IFS= read -r name; do
    cp "$src/$name" "$dest/$target/"
  done
  echo "collect-release: $target: $(wc -l < "$tmp/$target.sha256") files + manifest.json from $src"
done

find "$dest" -type f | sort
