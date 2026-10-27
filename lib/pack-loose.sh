#!/usr/bin/env bash
# Pack every loose object of a repo into a new pack, reachable or not, then drop the loose copies.
# The step sandbox denies writes to objects/pack, so packed objects cannot be overwritten by a step.
# `git repack -d` is not enough: it packs only reachable objects and leaves the rest loose.
#   usage: pack-loose.sh <git-dir>
set -euo pipefail
G=${1:?git-dir}
find "$G/objects" -path "$G/objects/pack" -prune -o -path "$G/objects/info" -prune -o -type f -print \
  | sed -E 's#.*/objects/(..)/(.{38})$#\1\2#' | grep -E '^[0-9a-f]{40}$' \
  | git --git-dir "$G" pack-objects -q "$G/objects/pack/pack" > /dev/null || true
git --git-dir "$G" prune-packed
# New loose objects may appear again at once (another process committing): that is expected, not a failure.
echo "pack-loose: $(git --git-dir "$G" count-objects | cut -d' ' -f1) loose objects after packing"
