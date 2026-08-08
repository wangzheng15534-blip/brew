#!/bin/bash
# Confinement and idempotence coverage for formula transaction recovery.
set -euo pipefail

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repo="$(cd "${repo}" && pwd -P)"
# shellcheck source=../../utils/overlay.sh
source "${repo}/Library/Homebrew/utils/overlay.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/homebrew-overlay-transaction-integrity.XXXXXX")"
trap 'rm -rf -- "${work}"' EXIT

make_case() {
  local root="$1"
  mkdir -p \
    "${root}/base/Cellar/foo/2.0/bin" \
    "${root}/base/opt" "${root}/base/var/homebrew/linked" \
    "${root}/user/Cellar" "${root}/user/bin" "${root}/user/sbin" \
    "${root}/user/include" "${root}/user/lib" "${root}/user/share" \
    "${root}/user/Frameworks" "${root}/user/opt" \
    "${root}/user/var/homebrew/linked" "${root}/user/var/homebrew/locks" \
    "${root}/user/var/homebrew/overlay/transactions" \
    "${root}/user/var/homebrew/overlay/sync"
  printf 'base\n' >"${root}/base/Cellar/foo/2.0/bin/foo"
  ln -s '../Cellar/foo/2.0' "${root}/base/opt/foo"
  ln -s '../../../Cellar/foo/2.0' "${root}/base/var/homebrew/linked/foo"
  ln -s "${root}/base/Cellar/foo" "${root}/user/Cellar/foo"
  homebrew-overlay-ensure-generation "${root}/base"
  homebrew-overlay-ensure-generation "${root}/user"
}

write_journal() {
  local root="$1" id="$2" state="$3"
  local transaction="${root}/user/var/homebrew/overlay/transactions/${id}"
  local generation
  mkdir -p "${transaction}"
  generation="$(homebrew-overlay-view-key "${root}/base")"
  printf 'foo\n' >"${transaction}/formula"
  printf '2.0\n' >"${transaction}/version"
  printf '%s\n' "${generation}" >"${transaction}/base_generation"
  printf '%s\n' "${state}" >"${transaction}/state"
}

activate() {
  local root="$1"
  export HOMEBREW_PREFIX="${root}/user"
  export HOMEBREW_OVERLAY_BASE_PREFIX="${root}/base"
  export HOMEBREW_OVERLAY=1
  export HOMEBREW_OVERLAY_ACTIVE=1
  unset HOMEBREW_OVERLAY_MUTATION_LOCK_FD HOMEBREW_OVERLAY_OWNER_TRANSACTION_ID \
    HOMEBREW_OVERLAY_OWNER_TRANSACTION_LOCK_FD
  unset HOMEBREW_OVERLAY_OWNER_TRANSACTION_ID HOMEBREW_OVERLAY_MUTATION_OWNER
}

# Rollback cleanup removes the transaction-owned rack before its journal. A
# crash in that interval leaves no ownership marker, but an exact restored rack
# proves that cleanup can finish safely and idempotently.
rolling="${work}/rolling-back-cleanup"
make_case "${rolling}"
write_journal "${rolling}" txn-rolling rolling-back
activate "${rolling}"
homebrew-overlay-sync --force
test -L "${rolling}/user/Cellar/foo"
test "$(readlink -f "${rolling}/user/Cellar/foo")" = "$(readlink -f "${rolling}/base/Cellar/foo")"
test ! -e "${rolling}/user/var/homebrew/overlay/transactions/txn-rolling"

# Recovery has the same cleanup window. A real inherited-version union is also
# valid only when it contains every and only the exact lower versions.
recovering="${work}/recovering-cleanup"
make_case "${recovering}"
write_journal "${recovering}" txn-recovering recovering-cleanup
rm "${recovering}/user/Cellar/foo"
mkdir "${recovering}/user/Cellar/foo"
ln -s "${recovering}/base/Cellar/foo/2.0" "${recovering}/user/Cellar/foo/2.0"
activate "${recovering}"
homebrew-overlay-sync --force
test -d "${recovering}/user/Cellar/foo" && test ! -L "${recovering}/user/Cellar/foo"
test ! -e "${recovering}/user/var/homebrew/overlay/transactions/txn-recovering"

# Markerless cleanup is accepted only with that exact proof. A hidden extra
# object is not silently discarded or blessed as an inherited rack.
nonexact="${work}/nonexact-cleanup"
make_case "${nonexact}"
write_journal "${nonexact}" txn-nonexact rolling-back
rm "${nonexact}/user/Cellar/foo"
mkdir "${nonexact}/user/Cellar/foo"
ln -s "${nonexact}/base/Cellar/foo/2.0" "${nonexact}/user/Cellar/foo/2.0"
printf 'unmanaged\n' >"${nonexact}/user/Cellar/foo/.extra"
activate "${nonexact}"
if homebrew-overlay-sync --force >"${nonexact}/stdout" 2>"${nonexact}/stderr"
then
  echo 'non-exact markerless rollback unexpectedly recovered' >&2
  exit 1
fi
grep -Eq 'does not own either recovery rack|did not restore an exact inherited rack' "${nonexact}/stderr"
test -f "${nonexact}/user/Cellar/foo/.extra"
test -d "${nonexact}/user/var/homebrew/overlay/transactions/txn-nonexact"

# Every hidden cleanup parent is validated before a pending journal can cause
# any recursive deletion. An intermediate symlink must leave outside data
# untouched for staging, replacement, and failed roots alike.
for parent in .homebrew-overlay-staging .homebrew-overlay-racks .homebrew-overlay-failed
do
  safe_name="${parent#.homebrew-overlay-}"
  hidden="${work}/hidden-${safe_name}"
  make_case "${hidden}"
  outside="${hidden}/outside/${safe_name}"
  mkdir -p "${outside}/txn-hidden"
  printf 'sentinel\n' >"${outside}/txn-hidden/sentinel"
  ln -s "${outside}" "${hidden}/user/Cellar/${parent}"
  mkdir -p "${hidden}/user/var/homebrew/overlay/transactions/.new-txn-hidden"
  activate "${hidden}"
  if homebrew-overlay-sync --force >"${hidden}/stdout" 2>"${hidden}/stderr"
  then
    echo "symlinked hidden parent unexpectedly recovered: ${parent}" >&2
    exit 1
  fi
  grep -qx 'sentinel' "${outside}/txn-hidden/sentinel"
  test -d "${hidden}/user/var/homebrew/overlay/transactions/.new-txn-hidden"
done

# Owner locks and journal metadata are authorization records. Hard links cannot
# smuggle another inode into either role, and their peer remains unchanged.
lock_case="${work}/hardlinked-owner-lock"
make_case "${lock_case}"
mkdir -p "${lock_case}/user/var/homebrew/overlay/transactions/.new-txn-lock" \
         "${lock_case}/user/var/homebrew/overlay/transactions/.locks"
printf 'owner-victim\n' >"${lock_case}/owner-victim"
chmod 0600 "${lock_case}/owner-victim"
ln "${lock_case}/owner-victim" \
  "${lock_case}/user/var/homebrew/overlay/transactions/.locks/txn-lock.lock"
activate "${lock_case}"
if homebrew-overlay-sync --force >"${lock_case}/stdout" 2>"${lock_case}/stderr"
then
  echo 'hard-linked transaction owner lock unexpectedly recovered' >&2
  exit 1
fi
grep -q 'unsafe pending overlay transaction owner lock' "${lock_case}/stderr"
grep -qx 'owner-victim' "${lock_case}/owner-victim"

metadata="${work}/hardlinked-metadata"
make_case "${metadata}"
write_journal "${metadata}" txn-metadata staging
printf 'staging\n' >"${metadata}/metadata-victim"
rm "${metadata}/user/var/homebrew/overlay/transactions/txn-metadata/state"
ln "${metadata}/metadata-victim" \
  "${metadata}/user/var/homebrew/overlay/transactions/txn-metadata/state"
activate "${metadata}"
if homebrew-overlay-sync --force >"${metadata}/stdout" 2>"${metadata}/stderr"
then
  echo 'hard-linked transaction metadata unexpectedly recovered' >&2
  exit 1
fi
grep -q 'unsafe overlay formula transaction metadata' "${metadata}/stderr"
grep -qx 'staging' "${metadata}/metadata-victim"

trailing="${work}/trailing-metadata"
make_case "${trailing}"
write_journal "${trailing}" txn-trailing staging
printf 'staging\nextra\n' >"${trailing}/user/var/homebrew/overlay/transactions/txn-trailing/state"
activate "${trailing}"
if homebrew-overlay-sync --force >"${trailing}/stdout" 2>"${trailing}/stderr"
then
  echo 'multi-line transaction state unexpectedly recovered' >&2
  exit 1
fi
grep -q 'unsafe overlay formula transaction metadata' "${trailing}/stderr"
test -d "${trailing}/user/var/homebrew/overlay/transactions/txn-trailing"

nul_state="${work}/nul-metadata"
make_case "${nul_state}"
write_journal "${nul_state}" txn-nul staging
printf 'staging\0\n' >"${nul_state}/user/var/homebrew/overlay/transactions/txn-nul/state"
activate "${nul_state}"
if homebrew-overlay-sync --force >"${nul_state}/stdout" 2>"${nul_state}/stderr"
then
  echo 'NUL-bearing transaction state unexpectedly recovered' >&2
  exit 1
fi
grep -q 'unsafe overlay formula transaction metadata' "${nul_state}/stderr"
test -d "${nul_state}/user/var/homebrew/overlay/transactions/txn-nul"

# A transaction marker itself must be a private one-link file; otherwise it
# cannot authorize rack exchange or deletion.
marker="${work}/hardlinked-marker"
make_case "${marker}"
write_journal "${marker}" txn-marker published
rm "${marker}/user/Cellar/foo"
mkdir -p "${marker}/user/Cellar/foo/2.0" \
  "${marker}/user/Cellar/.homebrew-overlay-racks/txn-marker"
ln -s "${marker}/base/Cellar/foo" \
  "${marker}/user/Cellar/.homebrew-overlay-racks/txn-marker/foo"
printf 'txn-marker\n' >"${marker}/marker-victim"
ln "${marker}/marker-victim" \
  "${marker}/user/Cellar/foo/2.0/.brew-overlay-transaction"
activate "${marker}"
if homebrew-overlay-sync --force >"${marker}/stdout" 2>"${marker}/stderr"
then
  echo 'hard-linked transaction marker unexpectedly recovered' >&2
  exit 1
fi
grep -q 'unsafe overlay formula transaction marker' "${marker}/stderr"
grep -qx 'txn-marker' "${marker}/marker-victim"
test -d "${marker}/user/Cellar/foo/2.0"

printf 'overlay transaction integrity test: PASS\n'
