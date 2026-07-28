#!/bin/bash
# Sync the vendored GPU-stack forks: check out the pinned upstream revisions
# into third_party/src/ and apply our patch series on top.
#
# The checkouts are gitignored — the fork is defined entirely by pins.env +
# patches/ (jj refuses to snapshot >1MiB files, and vendoring Mesa's tree
# would bloat the repo; pin+patches is the durable representation).
#
# Local git alternates: if ~/.local/src/{mesa-main,virglrenderer-upstream}
# exist they are used as --reference to avoid re-downloading.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./pins.env

sync_one() {
  local name="$1" url="$2" sha="$3" ref="$4"
  local dir="src/$name"
  if [ ! -d "$dir/.git" ]; then
    local refflag=()
    [ -d "$ref/.git" ] && refflag=(--reference-if-able "$ref" --dissociate)
    git clone "${refflag[@]}" --filter=tree:0 "$url" "$dir"
  fi
  git -C "$dir" fetch origin "$sha" 2>/dev/null || git -C "$dir" fetch origin
  git -C "$dir" checkout -f "$sha"
  git -C "$dir" clean -fd -e build -e build-macos -e build-kk
  local series=(patches/"$name"/*.patch)
  if [ -e "${series[0]}" ]; then
    for p in "${series[@]}"; do
      echo "applying $p"
      git -C "$dir" apply --index "../../$p" 2>/dev/null ||
        git -C "$dir" am --keep-cr "../../$p" 2>/dev/null ||
        git -C "$dir" apply "../../$p"
    done
  fi
  echo "$name @ $sha + $(ls patches/"$name"/*.patch 2>/dev/null | wc -l | tr -d ' ') patches"
}

mkdir -p src
sync_one virglrenderer "$VIRGLRENDERER_URL" "$VIRGLRENDERER_SHA" "$HOME/.local/src/virglrenderer-upstream"
sync_one mesa "$MESA_URL" "$MESA_SHA" "$HOME/.local/src/mesa-main"
echo "sync done"
