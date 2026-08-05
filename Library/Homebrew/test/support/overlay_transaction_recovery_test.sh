#!/bin/bash
# Crash-recovery coverage for every durable formula transaction phase.
set -euo pipefail

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repo="$(cd "${repo}" && pwd -P)"
# shellcheck source=../../utils/overlay.sh
source "${repo}/Library/Homebrew/utils/overlay.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/homebrew-overlay-transaction.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
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
  ln -s "../Cellar/foo/2.0" "${root}/base/opt/foo"
  ln -s "../../../Cellar/foo/2.0" "${root}/base/var/homebrew/linked/foo"
  ln -s "${root}/base/Cellar/foo" "${root}/user/Cellar/foo"
}

write_journal() {
  local root="$1" id="$2" state="$3"
  local transaction="${root}/user/var/homebrew/overlay/transactions/${id}"
  local generation
  mkdir -p "${transaction}"
  generation="$(homebrew-overlay-view-key "${root}/base")"
  homebrew-overlay-base-generation-valid "${generation}"
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
}

# Staging never changed the active rack.
case1="${work}/staging"
make_case "${case1}"
write_journal "${case1}" txn-staging staging
mkdir -p "${case1}/user/Cellar/.homebrew-overlay-staging/txn-staging/foo/2.0"
activate "${case1}"
homebrew-overlay-sync --force
test -L "${case1}/user/Cellar/foo"
test ! -e "${case1}/user/Cellar/.homebrew-overlay-staging/txn-staging"
test ! -e "${case1}/user/var/homebrew/overlay/transactions/txn-staging"

# Publication prepared a replacement but had not exchanged it.
case2="${work}/publishing-before-exchange"
make_case "${case2}"
write_journal "${case2}" txn-before publishing
mkdir -p "${case2}/user/Cellar/.homebrew-overlay-racks/txn-before/foo/2.0"
printf 'txn-before\n' >"${case2}/user/Cellar/.homebrew-overlay-racks/txn-before/foo/2.0/.brew-overlay-transaction"
activate "${case2}"
homebrew-overlay-sync --force
test -L "${case2}/user/Cellar/foo"
test ! -e "${case2}/user/Cellar/.homebrew-overlay-racks/txn-before"

# Publication exchanged the rack but had not committed it.
case3="${work}/published-after-exchange"
make_case "${case3}"
write_journal "${case3}" txn-published published
rm "${case3}/user/Cellar/foo"
mkdir -p "${case3}/user/Cellar/foo/2.0/bin" \
         "${case3}/user/Cellar/.homebrew-overlay-racks/txn-published"
printf 'local\n' >"${case3}/user/Cellar/foo/2.0/bin/foo"
printf 'txn-published\n' >"${case3}/user/Cellar/foo/2.0/.brew-overlay-transaction"
ln -s "${case3}/base/Cellar/foo" \
  "${case3}/user/Cellar/.homebrew-overlay-racks/txn-published/foo"
ln -s "../Cellar/foo/2.0/bin/foo" "${case3}/user/bin/foo"
activate "${case3}"
homebrew-overlay-sync --force
test -L "${case3}/user/Cellar/foo"
test "$(readlink "${case3}/user/Cellar/foo")" = "${case3}/base/Cellar/foo"
test ! -e "${case3}/user/bin/foo"
test ! -e "${case3}/user/Cellar/.homebrew-overlay-racks/txn-published"

# Recovery itself was interrupted after moving the failed rack aside.
case4="${work}/recovering-previous"
make_case "${case4}"
write_journal "${case4}" txn-recover recovering-previous
rm "${case4}/user/Cellar/foo"
mkdir -p "${case4}/user/Cellar/.homebrew-overlay-failed/txn-recover/foo/2.0" \
         "${case4}/user/Cellar/.homebrew-overlay-racks/txn-recover"
printf 'txn-recover\n' >"${case4}/user/Cellar/.homebrew-overlay-failed/txn-recover/foo/2.0/.brew-overlay-transaction"
ln -s "${case4}/base/Cellar/foo" \
  "${case4}/user/Cellar/.homebrew-overlay-racks/txn-recover/foo"
activate "${case4}"
homebrew-overlay-sync --force
test -L "${case4}/user/Cellar/foo"
test ! -e "${case4}/user/Cellar/.homebrew-overlay-failed/txn-recover"

# Committing is the durability boundary: keep the local rack and remove only
# transaction metadata and the previous rack.
case5="${work}/committing"
make_case "${case5}"
write_journal "${case5}" txn-commit committing
rm "${case5}/user/Cellar/foo"
mkdir -p "${case5}/user/Cellar/foo/2.0/bin" \
         "${case5}/user/Cellar/.homebrew-overlay-racks/txn-commit"
printf 'local\n' >"${case5}/user/Cellar/foo/2.0/bin/foo"
printf 'txn-commit\n' >"${case5}/user/Cellar/foo/2.0/.brew-overlay-transaction"
cp "${case5}/user/var/homebrew/overlay/transactions/txn-commit/base_generation" \
  "${case5}/user/Cellar/foo/2.0/.brew-overlay-base-generation"
ln -s "${case5}/base/Cellar/foo" \
  "${case5}/user/Cellar/.homebrew-overlay-racks/txn-commit/foo"
activate "${case5}"
homebrew-overlay-sync --force
test -d "${case5}/user/Cellar/foo/2.0"
test ! -L "${case5}/user/Cellar/foo"
test ! -e "${case5}/user/Cellar/foo/2.0/.brew-overlay-transaction"
test ! -e "${case5}/user/Cellar/.homebrew-overlay-racks/txn-commit"

# A foreign marker is corruption and must stop bootstrap without deleting data.
case6="${work}/foreign-marker"
make_case "${case6}"
write_journal "${case6}" txn-foreign committed
rm "${case6}/user/Cellar/foo"
mkdir -p "${case6}/user/Cellar/foo/2.0"
printf 'someone-else\n' >"${case6}/user/Cellar/foo/2.0/.brew-overlay-transaction"
cp "${case6}/user/var/homebrew/overlay/transactions/txn-foreign/base_generation" \
  "${case6}/user/Cellar/foo/2.0/.brew-overlay-base-generation"
activate "${case6}"
if homebrew-overlay-sync --force >"${case6}/stdout" 2>"${case6}/stderr"
then
  echo "foreign transaction marker unexpectedly recovered" >&2
  exit 1
fi
test -d "${case6}/user/Cellar/foo/2.0"
grep -q 'another transaction marker' "${case6}/stderr"

# A committed transaction without the exact generation marker is corruption;
# recovery must retain all evidence and stop.
case7="${work}/wrong-base-generation"
make_case "${case7}"
write_journal "${case7}" txn-generation committed
rm "${case7}/user/Cellar/foo"
mkdir -p "${case7}/user/Cellar/foo/2.0"
printf 'txn-generation\n' >"${case7}/user/Cellar/foo/2.0/.brew-overlay-transaction"
printf '%.0s0' {1..64} >"${case7}/user/Cellar/foo/2.0/.brew-overlay-base-generation"
printf '\n' >>"${case7}/user/Cellar/foo/2.0/.brew-overlay-base-generation"
activate "${case7}"
if homebrew-overlay-sync --force >"${case7}/stdout" 2>"${case7}/stderr"
then
  echo "wrong base-generation marker unexpectedly recovered" >&2
  exit 1
fi
test -d "${case7}/user/Cellar/foo/2.0"
test -d "${case7}/user/var/homebrew/overlay/transactions/txn-generation"
grep -q 'wrong base generation' "${case7}/stderr"

printf 'overlay transaction recovery test: PASS\n'
