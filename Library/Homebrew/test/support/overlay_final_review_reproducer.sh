#!/bin/bash
# Reproduce release-blocking defects found during the final native-overlay audit.
# This is an audit harness: success means the vulnerable behavior was observed.
set -euo pipefail

repository="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repository="$(cd "${repository}" && pwd -P)"
# shellcheck source=../../utils/overlay.sh
source "${repository}/Library/Homebrew/utils/overlay.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/homebrew-overlay-final-review.XXXXXX")"
owner_pid=""
cleanup() {
  if [[ -n "${owner_pid}" ]] && kill -0 "${owner_pid}" 2>/dev/null; then
    kill "${owner_pid}" 2>/dev/null || true
    wait "${owner_pid}" 2>/dev/null || true
  fi
  rm -rf -- "${work}"
}
trap cleanup EXIT
confirmed=0

make_prefixes() {
  local root="$1"
  mkdir -p \
    "${root}/base/Cellar/foo/1.0/bin" \
    "${root}/base/opt" \
    "${root}/base/var/homebrew/linked" \
    "${root}/user/Cellar" \
    "${root}/user/bin" \
    "${root}/user/sbin" \
    "${root}/user/include" \
    "${root}/user/lib" \
    "${root}/user/share" \
    "${root}/user/Frameworks" \
    "${root}/user/opt" \
    "${root}/user/var/homebrew/linked" \
    "${root}/user/var/homebrew/locks" \
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
}

write_journal() {
  local root="$1" id="$2" state="$3"
  local transaction="${root}/user/var/homebrew/overlay/transactions/${id}"
  local generation
  generation="$(homebrew-overlay-view-key "${root}/base")"
  homebrew-overlay-base-generation-valid "${generation}"
  mkdir -p "${transaction}"
  printf 'foo\n' >"${transaction}/formula"
  printf '2.0\n' >"${transaction}/version"
  printf '%s\n' "${generation}" >"${transaction}/base_generation"
  printf '%s\n' "${state}" >"${transaction}/state"
}

# R1: startup recovery does not distinguish a live transaction owner from a
# crashed process. A concurrent read-only brew invocation can remove the active
# process's staging tree and journal.
case_live="${work}/live-transaction"
make_prefixes "${case_live}"
ln -s "${case_live}/base/Cellar/foo" "${case_live}/user/Cellar/foo"
sleep 120 &
owner_pid=$!
transaction_id="${owner_pid}-live-owner"
write_journal "${case_live}" "${transaction_id}" staging
mkdir -p "${case_live}/user/Cellar/.homebrew-overlay-staging/${transaction_id}/foo/2.0"
printf 'in-progress\n' >"${case_live}/user/Cellar/.homebrew-overlay-staging/${transaction_id}/foo/2.0/payload"
activate "${case_live}"
homebrew-overlay-sync --force
kill -0 "${owner_pid}"
test ! -e "${case_live}/user/var/homebrew/overlay/transactions/${transaction_id}"
test ! -e "${case_live}/user/Cellar/.homebrew-overlay-staging/${transaction_id}"
printf 'CONFIRMED: live transaction owner remains running while recovery deletes its journal and staging tree\n'
confirmed=$((confirmed + 1))
kill "${owner_pid}" 2>/dev/null || true
wait "${owner_pid}" 2>/dev/null || true
owner_pid=""

# R2: a real version-union rack is not a fixed point. The desired view records
# only missing lower versions, so an already-correct inherited child is omitted
# from desired state and removed on the next reconciliation.
case_toggle="${work}/version-toggle"
make_prefixes "${case_toggle}"
mkdir -p "${case_toggle}/user/Cellar/foo"
activate "${case_toggle}"
homebrew-overlay-sync --force
test -L "${case_toggle}/user/Cellar/foo/1.0"
homebrew-overlay-sync --force
test ! -e "${case_toggle}/user/Cellar/foo/1.0"
test ! -L "${case_toggle}/user/Cellar/foo/1.0"
homebrew-overlay-sync --force
test -L "${case_toggle}/user/Cellar/foo/1.0"
printf 'CONFIRMED: repeated union-rack reconciliation alternately removes and recreates the inherited version\n'
confirmed=$((confirmed + 1))

# R3: an existing inherited-version child is accepted solely because a path is
# present. Its target is neither validated nor brought under view-state control.
case_wrong="${work}/wrong-target"
make_prefixes "${case_wrong}"
mkdir -p "${case_wrong}/user/Cellar/foo" "${case_wrong}/other/1.0"
ln -s "${case_wrong}/other/1.0" "${case_wrong}/user/Cellar/foo/1.0"
activate "${case_wrong}"
homebrew-overlay-sync --force
test "$(readlink "${case_wrong}/user/Cellar/foo/1.0")" = "${case_wrong}/other/1.0"
if tr '\0' '\n' <"${case_wrong}/user/var/homebrew/overlay/view.state" | grep -Fqx 'Cellar/foo/1.0'; then
  echo 'wrong-target child unexpectedly became managed' >&2
  exit 1
fi
printf 'CONFIRMED: synchronization preserves an incorrect version child and omits it from managed state\n'
confirmed=$((confirmed + 1))

# R4: transaction publication creates inherited child symlinks directly in a
# replacement rack. Because they already exist when synchronization runs, they
# are omitted from view state. A later base removal leaves a broken child.
case_broken="${work}/broken-after-base-removal"
make_prefixes "${case_broken}"
activate "${case_broken}"
homebrew-overlay-sync --force
rm "${case_broken}/user/Cellar/foo"
mkdir -p "${case_broken}/user/Cellar/foo/2.0"
ln -s "${case_broken}/base/Cellar/foo/1.0" "${case_broken}/user/Cellar/foo/1.0"
printf '%s\n' "$(homebrew-overlay-view-key "${case_broken}/base")" > \
  "${case_broken}/user/Cellar/foo/2.0/.brew-overlay-base-generation"
homebrew-overlay-bump-generation "${case_broken}/user" >/dev/null
homebrew-overlay-sync --force
test -L "${case_broken}/user/Cellar/foo/1.0"
if tr '\0' '\n' <"${case_broken}/user/var/homebrew/overlay/view.state" | grep -Fqx 'Cellar/foo/1.0'; then
  echo 'transaction-created inherited child unexpectedly became managed' >&2
  exit 1
fi
rm -rf "${case_broken}/base/Cellar/foo/1.0"
homebrew-overlay-bump-generation "${case_broken}/base" >/dev/null
homebrew-overlay-sync --force
test -L "${case_broken}/user/Cellar/foo/1.0"
test ! -e "${case_broken}/user/Cellar/foo/1.0"
printf 'CONFIRMED: base removal leaves a transaction-created inherited child broken and unmanaged\n'
confirmed=$((confirmed + 1))

# R5: rollback cleanup only removes symlinks. Native Homebrew linking also
# mutates regular metadata such as share/info/dir; this helper leaves that state
# behind after a failed transaction.
case_regular="${work}/regular-link-side-effect"
make_prefixes "${case_regular}"
mkdir -p "${case_regular}/user/Cellar/foo/2.0/share/info" "${case_regular}/user/share/info"
printf 'manual\n' >"${case_regular}/user/Cellar/foo/2.0/share/info/foo.info"
ln -s "../../Cellar/foo/2.0/share/info/foo.info" "${case_regular}/user/share/info/foo.info"
printf 'stale index entry for foo\n' >"${case_regular}/user/share/info/dir"
homebrew-overlay-remove-version-links \
  "${case_regular}/user" "${case_regular}/user/Cellar/foo/2.0"
test ! -L "${case_regular}/user/share/info/foo.info"
grep -Fqx 'stale index entry for foo' "${case_regular}/user/share/info/dir"
printf 'CONFIRMED: transaction rollback helper removes links but leaves regular link-tree metadata\n'
confirmed=$((confirmed + 1))

printf 'confirmed=%s expected=5\n' "${confirmed}"
test "${confirmed}" -eq 5
