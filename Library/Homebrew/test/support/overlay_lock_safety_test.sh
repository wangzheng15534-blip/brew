#!/bin/bash
# Advisory-lock integrity and administrator mutation exclusion coverage.
set -euo pipefail

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repo="$(cd "${repo}" && pwd -P)"
# shellcheck source=../../utils/overlay.sh
source "${repo}/Library/Homebrew/utils/overlay.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/homebrew-overlay-locks.XXXXXX")"
owner_pid=""
cleanup() {
  if [[ -n "${owner_pid}" ]] && kill -0 "${owner_pid}" 2>/dev/null
  then
    kill "${owner_pid}" 2>/dev/null || true
    wait "${owner_pid}" 2>/dev/null || true
  fi
  rm -rf -- "${work}"
}
trap cleanup EXIT

make_case() {
  local root="$1"
  mkdir -p \
    "${root}/base/Cellar/foo/1.0" \
    "${root}/base/opt" "${root}/base/var/homebrew/linked" \
    "${root}/user/Cellar" "${root}/user/opt" \
    "${root}/user/var/homebrew/linked" \
    "${root}/user/var/homebrew/overlay/transactions" \
    "${root}/user/var/homebrew/overlay/sync"
  ln -s "../Cellar/foo/1.0" "${root}/base/opt/foo"
  ln -s "../../../Cellar/foo/1.0" "${root}/base/var/homebrew/linked/foo"
  homebrew-overlay-ensure-generation "${root}/base"
  homebrew-overlay-ensure-generation "${root}/user"
}

activate() {
  local root="$1"
  export HOMEBREW_PREFIX="${root}/user"
  export HOMEBREW_OVERLAY_BASE_PREFIX="${root}/base"
  export HOMEBREW_OVERLAY=1
  export HOMEBREW_OVERLAY_ACTIVE=1
  unset HOMEBREW_OVERLAY_MUTATION_OWNER HOMEBREW_OVERLAY_FINALIZE_MUTATION
}

# A synchronization lock is control state. Opening it must never follow and
# truncate a user-selected symlink target.
case_symlink="${work}/sync-symlink"
make_case "${case_symlink}"
activate "${case_symlink}"
sync_lock="${case_symlink}/user/var/homebrew/locks/overlay-sync.lock"
victim="${case_symlink}/victim"
printf 'must-not-change\n' >"${victim}"
ln -s "${victim}" "${sync_lock}"
if homebrew-overlay-sync --force >"${case_symlink}/stdout" 2>"${case_symlink}/stderr"
then
  echo 'symlinked synchronization lock unexpectedly succeeded' >&2
  exit 1
fi
grep -q 'unsafe Homebrew overlay synchronization lock' "${case_symlink}/stderr"
grep -qx 'must-not-change' "${victim}"
test -L "${sync_lock}"

# A hard-linked lock could otherwise make validation chmod or truncate an
# unrelated regular file. Lock files must have exactly one directory entry.
case_hardlink="${work}/sync-hardlink"
make_case "${case_hardlink}"
activate "${case_hardlink}"
sync_lock="${case_hardlink}/user/var/homebrew/locks/overlay-sync.lock"
victim="${case_hardlink}/victim"
printf 'hardlink-victim\n' >"${victim}"
chmod 0600 "${victim}"
ln "${victim}" "${sync_lock}"
if homebrew-overlay-sync --force >"${case_hardlink}/stdout" 2>"${case_hardlink}/stderr"
then
  echo 'hard-linked synchronization lock unexpectedly succeeded' >&2
  exit 1
fi
grep -q 'unsafe Homebrew overlay synchronization lock' "${case_hardlink}/stderr"
grep -qx 'hardlink-victim' "${victim}"
test "$(stat -c '%a' "${victim}")" = 600

# The shared base lock closes the window between an administrator acquiring its
# mutation lock and publishing the dirty-generation marker. Neither sync nor a
# base-generation read may observe the transient Cellar in that window.
case_base_live="${work}/base-live-before-dirty"
make_case "${case_base_live}"
activate "${case_base_live}"
homebrew-overlay-sync --force
base_lock="$(homebrew-overlay-mutation-lock-file "${case_base_live}/base")"
ready="${case_base_live}/ready"
stop="${case_base_live}/stop"
(
  exec 8<>"${base_lock}"
  flock -x 8
  mkdir -p "${case_base_live}/base/Cellar/transient/2.0"
  : >"${ready}"
  while [[ ! -e "${stop}" ]]
  do
    sleep 0.05
  done
) &
owner_pid=$!
for _ in {1..200}
do
  [[ -e "${ready}" ]] && break
  sleep 0.01
done
test -e "${ready}"
if homebrew-overlay-sync --force >"${case_base_live}/sync.out" 2>"${case_base_live}/sync.err"
then
  echo 'live administrator mutation without dirty marker unexpectedly synchronized' >&2
  exit 1
fi
grep -q 'administrator Homebrew prefix is being mutated' "${case_base_live}/sync.err"
test ! -e "${case_base_live}/user/Cellar/transient"
if HOMEBREW_OVERLAY_BASE_PREFIX="${case_base_live}/base" \
  bash "${repo}/Library/Homebrew/utils/overlay.sh" --base-generation \
  >"${case_base_live}/generation.out" 2>"${case_base_live}/generation.err"
then
  echo 'base-generation read crossed a live administrator mutation' >&2
  exit 1
fi
grep -q 'administrator Homebrew prefix is being mutated' "${case_base_live}/generation.err"
: >"${stop}"
wait "${owner_pid}"
owner_pid=""
homebrew-overlay-sync --force
test -L "${case_base_live}/user/Cellar/transient"

printf 'overlay lock safety test: PASS\n'
