#!/bin/bash
# Descriptor-bound authorization for nested mutation and transaction sync.
set -euo pipefail

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repo="$(cd "${repo}" && pwd -P)"
# shellcheck source=../../utils/overlay.sh
source "${repo}/Library/Homebrew/utils/overlay.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/homebrew-overlay-lock-ownership.XXXXXX")"
trap 'exec 20>&- 21>&- 22>&- 23>&- 2>/dev/null || true; rm -rf -- "${work}"' EXIT

make_case() {
  local root="$1"
  mkdir -p \
    "${root}/base/Cellar/foo/1.0/bin" \
    "${root}/base/opt" "${root}/base/var/homebrew/linked" \
    "${root}/user/Cellar" "${root}/user/bin" "${root}/user/sbin" \
    "${root}/user/include" "${root}/user/lib" "${root}/user/share" \
    "${root}/user/Frameworks" "${root}/user/opt" \
    "${root}/user/var/homebrew/linked" \
    "${root}/user/var/homebrew/overlay/transactions/.locks" \
    "${root}/user/var/homebrew/overlay/sync"
  printf 'base\n' >"${root}/base/Cellar/foo/1.0/bin/foo"
  ln -s '../Cellar/foo/1.0' "${root}/base/opt/foo"
  ln -s '../../../Cellar/foo/1.0' "${root}/base/var/homebrew/linked/foo"
  homebrew-overlay-ensure-generation "${root}/base"
  homebrew-overlay-ensure-generation "${root}/user"
}

activate() {
  local root="$1"
  export HOMEBREW_PREFIX="${root}/user"
  export HOMEBREW_OVERLAY_BASE_PREFIX="${root}/base"
  export HOMEBREW_OVERLAY=1
  export HOMEBREW_OVERLAY_ACTIVE=1
  unset HOMEBREW_OVERLAY_MUTATION_OWNER HOMEBREW_OVERLAY_FINALIZE_MUTATION \
    HOMEBREW_OVERLAY_MUTATION_LOCK_FD HOMEBREW_OVERLAY_OWNER_TRANSACTION_ID \
    HOMEBREW_OVERLAY_OWNER_TRANSACTION_LOCK_FD
}

write_journal() {
  local root="$1" id="$2"
  local transaction="${root}/user/var/homebrew/overlay/transactions/${id}"
  mkdir -p "${transaction}" \
    "${root}/user/Cellar/.homebrew-overlay-staging/${id}/foo/2.0"
  printf 'foo\n' >"${transaction}/formula"
  printf '2.0\n' >"${transaction}/version"
  homebrew-overlay-view-key "${root}/base" >"${transaction}/base_generation"
  printf 'staging\n' >"${transaction}/state"
  chmod 0600 "${transaction}"/*
}

case_root="${work}/ownership"
make_case "${case_root}"
activate "${case_root}"
homebrew-overlay-sync --force
mutation_lock="$(homebrew-overlay-mutation-lock-file "${case_root}/user")"

# Readable lock-file contents are not authority. A same-user process replaying
# the former token must remain excluded by the real owner's flock.
exec 20<>"${mutation_lock}"
flock -x 20
printf 'replayable-owner-token-0001\n' >"${mutation_lock}"
if HOMEBREW_OVERLAY_MUTATION_OWNER='replayable-owner-token-0001' \
  homebrew-overlay-sync --force >"${case_root}/token.out" 2>"${case_root}/token.err"
then
  echo 'replayed mutation-owner token unexpectedly synchronized' >&2
  exit 1
fi
grep -q 'another Homebrew package mutation is still active' "${case_root}/token.err"

# Reopening the same inode creates a different open-file description and must
# not authorize nested synchronization.
exec 21<>"${mutation_lock}"
if HOMEBREW_OVERLAY_MUTATION_LOCK_FD=21 \
  homebrew-overlay-sync --force >"${case_root}/reopen.out" 2>"${case_root}/reopen.err"
then
  echo 'reopened mutation descriptor unexpectedly synchronized' >&2
  exit 1
fi
grep -q 'unsafe inherited Homebrew overlay mutation lock descriptor' "${case_root}/reopen.err"
exec 21>&-

# The actual inherited, lock-owning descriptor authorizes a nested sync.
HOMEBREW_OVERLAY_MUTATION_LOCK_FD=20 homebrew-overlay-sync --force

txn='txn-live-owner'
write_journal "${case_root}" "${txn}"
owner_lock="${case_root}/user/var/homebrew/overlay/transactions/.locks/${txn}.lock"
(umask 077; : >"${owner_lock}")
exec 22<>"${owner_lock}"
flock -x 22

# A transaction identifier is not authorization without both live inherited
# descriptors.
if HOMEBREW_OVERLAY_MUTATION_LOCK_FD=20 \
  HOMEBREW_OVERLAY_OWNER_TRANSACTION_ID="${txn}" \
  homebrew-overlay-sync --force >"${case_root}/id-only.out" 2>"${case_root}/id-only.err"
then
  echo 'transaction identifier without owner descriptor unexpectedly synchronized' >&2
  exit 1
fi
grep -q 'incomplete inherited overlay transaction ownership' "${case_root}/id-only.err"

exec 23<>"${owner_lock}"
if HOMEBREW_OVERLAY_MUTATION_LOCK_FD=20 \
  HOMEBREW_OVERLAY_OWNER_TRANSACTION_ID="${txn}" \
  HOMEBREW_OVERLAY_OWNER_TRANSACTION_LOCK_FD=23 \
  homebrew-overlay-sync --force >"${case_root}/txn-reopen.out" 2>"${case_root}/txn-reopen.err"
then
  echo 'reopened transaction descriptor unexpectedly synchronized' >&2
  exit 1
fi
grep -q 'unsafe inherited overlay transaction owner lock descriptor' "${case_root}/txn-reopen.err"
exec 23>&-

# Both original descriptors permit the owner to synchronize without recovering
# its own still-live journal.
HOMEBREW_OVERLAY_MUTATION_LOCK_FD=20 \
HOMEBREW_OVERLAY_OWNER_TRANSACTION_ID="${txn}" \
HOMEBREW_OVERLAY_OWNER_TRANSACTION_LOCK_FD=22 \
  homebrew-overlay-sync --force
test -d "${case_root}/user/var/homebrew/overlay/transactions/${txn}"
test -d "${case_root}/user/Cellar/.homebrew-overlay-staging/${txn}"

# Once the descriptors close, ordinary recovery acquires both locks and removes
# the abandoned staging transaction.
exec 22>&-
exec 20>&-
homebrew-overlay-sync --force
test ! -e "${case_root}/user/var/homebrew/overlay/transactions/${txn}"
test ! -e "${case_root}/user/Cellar/.homebrew-overlay-staging/${txn}"
test ! -e "${owner_lock}"

printf 'overlay lock ownership test: PASS\n'
