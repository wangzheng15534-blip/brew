#!/bin/bash
# Crash-consistency coverage for explicit overlay package generations.
set -euo pipefail

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repo="$(cd "${repo}" && pwd -P)"
# shellcheck source=../../utils/overlay.sh
source "${repo}/Library/Homebrew/utils/overlay.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/homebrew-overlay-generation.XXXXXX")"
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
    "${root}/base/Cellar/foo/1.0/bin" \
    "${root}/base/opt" "${root}/base/var/homebrew/linked" \
    "${root}/base/var/homebrew/locks" \
    "${root}/user/Cellar" "${root}/user/bin" "${root}/user/sbin" \
    "${root}/user/include" "${root}/user/lib" "${root}/user/share" \
    "${root}/user/Frameworks" "${root}/user/opt" \
    "${root}/user/var/homebrew/linked" "${root}/user/var/homebrew/locks" \
    "${root}/user/var/homebrew/overlay/transactions" \
    "${root}/user/var/homebrew/overlay/sync"
  printf 'base\n' >"${root}/base/Cellar/foo/1.0/bin/foo"
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

# A crashed user mutation leaves the explicit generation unchanged but a dirty
# marker behind. The next invocation must structurally reconcile, publish a
# generation matching the recovered structure, and clear the marker.
case_user="${work}/user-crash"
make_case "${case_user}"
activate "${case_user}"
homebrew-overlay-sync --force
old_generation="$(homebrew-overlay-read-generation "${case_user}/user")"
mutation_lock="$(homebrew-overlay-prepare-mutation-lock "${case_user}/user")"
(
  flock -x 8
  printf '%s\n' 'crashed-user-owner-token-0001' >"${mutation_lock}"
  homebrew-overlay-mark-generation-dirty "${case_user}/user"
  mkdir -p "${case_user}/user/Cellar/local-only/1.0"
) 8<>"${mutation_lock}"
test -f "$(homebrew-overlay-generation-dirty-file "${case_user}/user")"
test "$(homebrew-overlay-read-generation "${case_user}/user")" = "${old_generation}"
# Matching stale content is insufficient: only the process that still holds the
# advisory lock may use an owner token to finalize a mutation.
export HOMEBREW_OVERLAY_MUTATION_OWNER='crashed-user-owner-token-0001'
export HOMEBREW_OVERLAY_FINALIZE_MUTATION=1
if homebrew-overlay-sync >"${case_user}/stale-owner.out" 2>"${case_user}/stale-owner.err"
then
  echo 'stale mutation owner token unexpectedly synchronized' >&2
  exit 1
fi
grep -q 'not backed by an active lock' "${case_user}/stale-owner.err"
unset HOMEBREW_OVERLAY_MUTATION_OWNER HOMEBREW_OVERLAY_FINALIZE_MUTATION
test -f "$(homebrew-overlay-generation-dirty-file "${case_user}/user")"
homebrew-overlay-sync
test ! -e "$(homebrew-overlay-generation-dirty-file "${case_user}/user")"
recovered_generation="$(homebrew-overlay-read-generation "${case_user}/user")"
test "${recovered_generation}" = "$(homebrew-overlay-structural-view-key "${case_user}/user")"
test "${recovered_generation}" != "${old_generation}"
test -L "${case_user}/user/Cellar/foo"

# A live package mutation owns the global lock. A second invocation must fail
# without clearing its dirty marker or consuming its in-progress filesystem
# changes. Once the owner exits, the same invocation path recovers the crash.
case_live="${work}/live-owner"
make_case "${case_live}"
activate "${case_live}"
homebrew-overlay-sync --force
mutation_lock="$(homebrew-overlay-prepare-mutation-lock "${case_live}/user")"
ready="${case_live}/owner-ready"
(
  flock -x 8
  printf '%s\n' 'live-user-owner-token-000002' >"${mutation_lock}"
  homebrew-overlay-mark-generation-dirty "${case_live}/user"
  mkdir -p "${case_live}/user/Cellar/live-local/1.0"
  : >"${ready}"
  while :
  do
    sleep 0.1
  done
) 8<>"${mutation_lock}" &
owner_pid=$!
for _ in {1..200}
do
  [[ -f "${ready}" ]] && break
  sleep 0.01
done
test -f "${ready}"
if homebrew-overlay-sync --force >"${case_live}/stdout" 2>"${case_live}/stderr"
then
  echo 'live mutation unexpectedly synchronized' >&2
  exit 1
fi
grep -q 'package mutation is still active' "${case_live}/stderr"
test -f "$(homebrew-overlay-generation-dirty-file "${case_live}/user")"
test -d "${case_live}/user/Cellar/live-local/1.0"
kill "${owner_pid}" 2>/dev/null || true
wait "${owner_pid}" 2>/dev/null || true
owner_pid=""
homebrew-overlay-sync --force
test ! -e "$(homebrew-overlay-generation-dirty-file "${case_live}/user")"
test -d "${case_live}/user/Cellar/live-local/1.0"

# A crashed administrator mutation is detected structurally by a developer.
# Developers do not clear the administrator marker; a later administrator
# recovery publishes the structural generation while holding the base lock.
case_base="${work}/base-crash"
make_case "${case_base}"
activate "${case_base}"
homebrew-overlay-sync --force
base_lock="$(homebrew-overlay-prepare-mutation-lock "${case_base}/base")"
(
  flock -x 8
  printf '%s\n' 'crashed-base-owner-token-0001' >"${base_lock}"
  homebrew-overlay-mark-generation-dirty "${case_base}/base"
  mkdir -p "${case_base}/base/Cellar/new-base/2.0"
) 8<>"${base_lock}"
test -f "$(homebrew-overlay-generation-dirty-file "${case_base}/base")"
homebrew-overlay-sync
test -L "${case_base}/user/Cellar/new-base"
test -f "$(homebrew-overlay-generation-dirty-file "${case_base}/base")"
(
  flock -x 8
  homebrew-overlay-recover-generation "${case_base}/base" >/dev/null
) 8<>"${base_lock}"
test ! -e "$(homebrew-overlay-generation-dirty-file "${case_base}/base")"
test "$(homebrew-overlay-read-generation "${case_base}/base")" = \
  "$(homebrew-overlay-structural-view-key "${case_base}/base")"
homebrew-overlay-sync

# A live administrator mutation blocks developer reconciliation rather than
# exposing a transient lower package view.
case_base_live="${work}/base-live"
make_case "${case_base_live}"
activate "${case_base_live}"
homebrew-overlay-sync --force
base_lock="$(homebrew-overlay-prepare-mutation-lock "${case_base_live}/base")"
ready="${case_base_live}/owner-ready"
(
  flock -x 8
  printf '%s\n' 'live-base-owner-token-000002' >"${base_lock}"
  homebrew-overlay-mark-generation-dirty "${case_base_live}/base"
  mkdir -p "${case_base_live}/base/Cellar/transient-base/3.0"
  : >"${ready}"
  while :
  do
    sleep 0.1
  done
) 8<>"${base_lock}" &
owner_pid=$!
for _ in {1..200}
do
  [[ -f "${ready}" ]] && break
  sleep 0.01
done
test -f "${ready}"
if homebrew-overlay-sync --force >"${case_base_live}/stdout" 2>"${case_base_live}/stderr"
then
  echo 'live administrator mutation unexpectedly synchronized' >&2
  exit 1
fi
grep -q 'administrator Homebrew prefix is being mutated' "${case_base_live}/stderr"
test ! -e "${case_base_live}/user/Cellar/transient-base"
kill "${owner_pid}" 2>/dev/null || true
wait "${owner_pid}" 2>/dev/null || true
owner_pid=""
homebrew-overlay-sync --force
test -L "${case_base_live}/user/Cellar/transient-base"

# A dirty marker is control state. Symlinks and malformed content are rejected
# without deleting or blessing the underlying package view.
case_unsafe="${work}/unsafe-marker"
make_case "${case_unsafe}"
activate "${case_unsafe}"
homebrew-overlay-sync --force
outside="${case_unsafe}/outside"
printf '%064d\n' 0 >"${outside}"
ln -s "${outside}" "$(homebrew-overlay-generation-dirty-file "${case_unsafe}/user")"
if homebrew-overlay-sync --force >"${case_unsafe}/stdout" 2>"${case_unsafe}/stderr"
then
  echo 'unsafe dirty marker unexpectedly synchronized' >&2
  exit 1
fi
grep -q 'invalid Homebrew overlay dirty generation marker' "${case_unsafe}/stderr"
test -L "$(homebrew-overlay-generation-dirty-file "${case_unsafe}/user")"
test -f "${outside}"

printf 'overlay generation recovery test: PASS\n'
