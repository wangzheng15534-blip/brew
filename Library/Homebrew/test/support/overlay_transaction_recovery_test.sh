#!/bin/bash
# Crash-recovery coverage for every durable formula transaction phase.
set -euo pipefail

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repo="$(cd "${repo}" && pwd -P)"
# shellcheck source=../../utils/overlay.sh
source "${repo}/Library/Homebrew/utils/overlay.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/homebrew-overlay-transaction.XXXXXX")"
owner_pid=""
cleanup() {
  if [[ -n "${owner_pid}" ]] && kill -0 "${owner_pid}" 2>/dev/null
  then
    kill "${owner_pid}" 2>/dev/null || true
    wait "${owner_pid}" 2>/dev/null || true
  fi
  rm -rf "${work}"
}
trap cleanup EXIT
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


# Journal creation is atomic: a hidden pending directory is never interpreted
# as a visible, corrupt transaction. A live owner preserves it and blocks
# startup; after the owner exits, recovery removes the pending journal and all
# transaction-owned staging paths.
pending_case="${work}/pending-owner"
make_case "${pending_case}"
mkdir -p \
  "${pending_case}/user/var/homebrew/overlay/transactions/.new-txn-pending" \
  "${pending_case}/user/var/homebrew/overlay/transactions/.locks" \
  "${pending_case}/user/Cellar/.homebrew-overlay-staging/txn-pending/foo/2.0" \
  "${pending_case}/user/Cellar/.homebrew-overlay-racks/txn-pending/foo" \
  "${pending_case}/user/Cellar/.homebrew-overlay-failed/txn-pending/foo"
: >"${pending_case}/user/var/homebrew/overlay/transactions/.locks/txn-pending.lock"
pending_ready="${pending_case}/owner-ready"
pending_lock="${pending_case}/user/var/homebrew/overlay/transactions/.locks/txn-pending.lock"
python3 - "${pending_lock}" "${pending_ready}" <<'PY_PENDING_OWNER' &
import fcntl
import pathlib
import sys
import time

lock_path = pathlib.Path(sys.argv[1])
ready_path = pathlib.Path(sys.argv[2])
with lock_path.open("r+") as lock:
    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
    ready_path.write_text("ready\n", encoding="utf-8")
    time.sleep(120)
PY_PENDING_OWNER
owner_pid=$!
for _ in {1..100}
do
  [[ -f "${pending_ready}" ]] && break
  sleep 0.01
done
test -f "${pending_ready}"
activate "${pending_case}"
if homebrew-overlay-sync --force >"${pending_case}/stdout" 2>"${pending_case}/stderr"
then
  echo "live pending overlay transaction unexpectedly synchronized" >&2
  exit 1
fi
test -d "${pending_case}/user/var/homebrew/overlay/transactions/.new-txn-pending"
test -d "${pending_case}/user/Cellar/.homebrew-overlay-staging/txn-pending"
grep -q 'transaction is still active' "${pending_case}/stderr"
kill "${owner_pid}" 2>/dev/null || true
wait "${owner_pid}" 2>/dev/null || true
owner_pid=""
homebrew-overlay-sync --force
test ! -e "${pending_case}/user/var/homebrew/overlay/transactions/.new-txn-pending"
test ! -e "${pending_case}/user/var/homebrew/overlay/transactions/.locks/txn-pending.lock"
test ! -e "${pending_case}/user/Cellar/.homebrew-overlay-staging/txn-pending"
test ! -e "${pending_case}/user/Cellar/.homebrew-overlay-racks/txn-pending"
test ! -e "${pending_case}/user/Cellar/.homebrew-overlay-failed/txn-pending"

# A process may die after acquiring its owner lock but before creating even a
# hidden journal. An unlocked orphan is cleaned; a malformed visible journal
# remains a hard error rather than being silently discarded.
orphan_case="${work}/orphan-owner-lock"
make_case "${orphan_case}"
mkdir -p "${orphan_case}/user/var/homebrew/overlay/transactions/.locks"
: >"${orphan_case}/user/var/homebrew/overlay/transactions/.locks/txn-orphan.lock"
activate "${orphan_case}"
homebrew-overlay-sync --force
test ! -e "${orphan_case}/user/var/homebrew/overlay/transactions/.locks/txn-orphan.lock"

incomplete_case="${work}/incomplete-visible-journal"
make_case "${incomplete_case}"
mkdir -p \
  "${incomplete_case}/user/var/homebrew/overlay/transactions/txn-incomplete" \
  "${incomplete_case}/user/var/homebrew/overlay/transactions/.locks"
: >"${incomplete_case}/user/var/homebrew/overlay/transactions/txn-incomplete/formula"
printf 'foo\n' >"${incomplete_case}/user/var/homebrew/overlay/transactions/txn-incomplete/formula"
: >"${incomplete_case}/user/var/homebrew/overlay/transactions/.locks/txn-incomplete.lock"
activate "${incomplete_case}"
if homebrew-overlay-sync --force >"${incomplete_case}/stdout" 2>"${incomplete_case}/stderr"
then
  echo "incomplete visible overlay transaction unexpectedly synchronized" >&2
  exit 1
fi
test -d "${incomplete_case}/user/var/homebrew/overlay/transactions/txn-incomplete"
grep -q 'incomplete overlay formula transaction' "${incomplete_case}/stderr"

# A live transaction owns a dedicated advisory lock. Startup must fail without
# touching its journal or staging tree; after the owner exits, normal recovery
# may remove the abandoned transaction.
case0="${work}/live-owner"
make_case "${case0}"
write_journal "${case0}" txn-live staging
mkdir -p "${case0}/user/Cellar/.homebrew-overlay-staging/txn-live/foo/2.0" \
         "${case0}/user/var/homebrew/overlay/transactions/.locks"
: >"${case0}/user/var/homebrew/overlay/transactions/.locks/txn-live.lock"
ready="${case0}/owner-ready"
python3 - "${case0}/user/var/homebrew/overlay/transactions/.locks/txn-live.lock" "${ready}" <<'PY_OWNER' &
import fcntl
import pathlib
import sys
import time

lock_path = pathlib.Path(sys.argv[1])
ready_path = pathlib.Path(sys.argv[2])
with lock_path.open("r+") as lock:
    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
    ready_path.write_text("ready\n", encoding="utf-8")
    time.sleep(120)
PY_OWNER
owner_pid=$!
for _ in {1..100}
do
  [[ -f "${ready}" ]] && break
  sleep 0.01
done
test -f "${ready}"
activate "${case0}"
if homebrew-overlay-sync --force >"${case0}/stdout" 2>"${case0}/stderr"
then
  echo "live overlay transaction unexpectedly synchronized" >&2
  exit 1
fi
test -d "${case0}/user/var/homebrew/overlay/transactions/txn-live"
test -d "${case0}/user/Cellar/.homebrew-overlay-staging/txn-live"
grep -q 'transaction is still active' "${case0}/stderr"
HOMEBREW_OVERLAY_OWNER_TRANSACTION_ID=txn-live homebrew-overlay-sync --force
test -d "${case0}/user/var/homebrew/overlay/transactions/txn-live"
test -d "${case0}/user/Cellar/.homebrew-overlay-staging/txn-live"
kill "${owner_pid}" 2>/dev/null || true
wait "${owner_pid}" 2>/dev/null || true
owner_pid=""
homebrew-overlay-sync --force
test ! -e "${case0}/user/var/homebrew/overlay/transactions/txn-live"
test ! -e "${case0}/user/Cellar/.homebrew-overlay-staging/txn-live"

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

python3 - "${repo}/Library/Homebrew/overlay.rb" <<'PY_ORDER'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
start = source.index("      def start!\n")
finish = source.index("      sig { void }\n      def publish!", start)
body = source[start:finish]
expected = [
    "acquire_owner_lock!",
    "Overlay.begin_mutation!",
    "Overlay.verify_base_generation!",
    "Overlay.ensure_inherited_rack!",
    "publish_journal!",
    "Overlay.ensure_owned_directory!(staging_rack)",
]
positions = [body.index(item) for item in expected]
assert positions == sorted(positions), positions
assert "write_metadata_at(@pending_transaction_dir" in source
assert "File.rename(@pending_transaction_dir, transaction_dir)" in source
PY_ORDER

printf 'overlay transaction recovery test: PASS\n'
