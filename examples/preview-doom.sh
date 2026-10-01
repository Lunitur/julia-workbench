#!/usr/bin/env bash
# Preview the exact migration in a copied configuration and package data tree.
set -euo pipefail

workbench_directory=$(cd -- "$(dirname -- "$0")/.." && pwd)
workbench_doom_directory=${DOOMDIR:-$HOME/.config/doom}
workbench_emacs_directory=${EMACSDIR:-$HOME/.config/emacs}
workbench_local_directory=${DOOMLOCALDIR:-$workbench_emacs_directory/.local}
mkdir -p "$workbench_directory/test/results/doom-migration"
workbench_preview=$(mktemp -d "$workbench_directory/test/results/doom-migration/preview.XXXXXX")
workbench_candidate="$workbench_preview/nixos/modules/features/editors/emacs/doom"
mkdir -p "$workbench_candidate" "$workbench_preview/local"
cp -a "$workbench_doom_directory/." "$workbench_candidate/"
if patch --dry-run --batch --forward -p1 -d "$workbench_preview/nixos" \
    < "$workbench_directory/examples/doom-migration.patch" > "$workbench_preview/patch.log" 2>&1; then
  patch --batch --forward -p1 -d "$workbench_preview/nixos" \
    < "$workbench_directory/examples/doom-migration.patch"
elif patch --dry-run --batch --reverse -p1 -d "$workbench_preview/nixos" \
    < "$workbench_directory/examples/doom-migration.patch" >> "$workbench_preview/patch.log" 2>&1; then
  printf 'Doom configuration already contains the migration; previewing its copy.\n'
else
  cat "$workbench_preview/patch.log" >&2
  exit 1
fi
# Reflinks avoid copying package data on supporting filesystems.  Never share
# writable package trees or build caches with the active Doom installation.
for workbench_part in straight etc env state; do
  if [[ -e "$workbench_local_directory/$workbench_part" ]]; then
    cp -a --reflink=auto "$workbench_local_directory/$workbench_part" "$workbench_preview/local/"
  fi
done
# Existing builds contain absolute source symlinks.  Point those at the copied
# repositories so any preview build operates entirely inside preview data.
while IFS= read -r -d '' workbench_link; do
  workbench_target=$(readlink "$workbench_link")
  if [[ "$workbench_target" == "$workbench_local_directory/straight/repos/"* ]]; then
    ln -sfn "$workbench_preview/local/straight/repos/${workbench_target#"$workbench_local_directory/straight/repos/"}" "$workbench_link"
  fi
done < <(find "$workbench_preview/local/straight" -type l -print0)
export DOOMDIR="$workbench_candidate"
export DOOMLOCALDIR="$workbench_preview/local"
export DOOMPROFILELOADFILE="$workbench_preview/profiles.el"
printf 'Preview data and sync log: %s\n' "$workbench_preview"
"$workbench_emacs_directory/bin/doom" sync -U -B > "$workbench_preview/sync.log" 2>&1
"${EMACS:-emacs}" --init-directory "$workbench_emacs_directory" \
  -l "$workbench_directory/test/doom-integration-tests.el" \
  --eval '(run-at-time 2 nil (function workbench-doom-run))'
JULIA_WORKBENCH_CORFU_RESULTS=corfu-doom-migration \
  "${EMACS:-emacs}" --init-directory "$workbench_emacs_directory" \
  -L "$workbench_directory/test" --eval '(setq load-prefer-newer t)' \
  -l "$workbench_directory/test/completion-corfu-tests.el" \
  --eval '(run-at-time 2 nil (function workbench-corfu-run))'
