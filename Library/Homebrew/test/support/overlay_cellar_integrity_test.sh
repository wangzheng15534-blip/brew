#!/bin/bash
# Complete Cellar validation and state-loss recovery for the managed package view.
set -euo pipefail

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repo="$(cd "${repo}" && pwd -P)"
# shellcheck source=../../utils/overlay.sh
source "${repo}/Library/Homebrew/utils/overlay.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/homebrew-overlay-cellar-integrity.XXXXXX")"
trap 'rm -rf -- "${work}"' EXIT

make_case() {
  local root="$1"
  mkdir -p \
    "${root}/base/Cellar/foo/1.0/bin" \
    "${root}/base/opt" "${root}/base/var/homebrew/linked" \
    "${root}/user/Cellar" "${root}/user/bin" "${root}/user/sbin" \
    "${root}/user/include" "${root}/user/lib" "${root}/user/share" \
    "${root}/user/Frameworks" "${root}/user/opt" \
    "${root}/user/var/homebrew/linked" "${root}/user/var/homebrew/locks" \
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
  unset HOMEBREW_OVERLAY_OWNER_TRANSACTION_ID HOMEBREW_OVERLAY_MUTATION_OWNER
}

mark_local_keg() {
  local root="$1" keg="$2"
  printf '%s\n' "$(homebrew-overlay-view-key "${root}/base")" > \
    "${keg}/.brew-overlay-base-generation"
}

state_has_relative() {
  local state="$1" expected="$2"
  python3 - "${state}" "${expected}" <<'PY_STATE'
import pathlib
import sys

fields = pathlib.Path(sys.argv[1]).read_bytes().split(b"\0")
entries = dict(zip(fields[0::2], fields[1::2]))
raise SystemExit(0 if sys.argv[2].encode() in entries else 1)
PY_STATE
}

# Losing the state file itself is recoverable without a generation change.
# Exact live links are rediscovered and published into a fresh state map.
missing_state="${work}/missing-state"
make_case "${missing_state}"
activate "${missing_state}"
homebrew-overlay-sync --force
rm "${missing_state}/user/var/homebrew/overlay/view.state"
homebrew-overlay-sync
test -s "${missing_state}/user/var/homebrew/overlay/view.state"
state_has_relative "${missing_state}/user/var/homebrew/overlay/view.state" 'Cellar/foo'
test "$(readlink "${missing_state}/user/Cellar/foo")" = "${missing_state}/base/Cellar/foo"

# A real rack is a union of real local keg directories and exact inherited
# links. A symlink at any other version name is a conflict even when that name
# does not exist in the current administrator rack.
wrong_link="${work}/wrong-extra-link"
make_case "${wrong_link}"
mkdir -p "${wrong_link}/user/Cellar/foo/2.0" "${wrong_link}/outside/9.9"
mark_local_keg "${wrong_link}" "${wrong_link}/user/Cellar/foo/2.0"
ln -s "${wrong_link}/outside/9.9" "${wrong_link}/user/Cellar/foo/9.9"
activate "${wrong_link}"
if homebrew-overlay-sync --force >"${wrong_link}/stdout" 2>"${wrong_link}/stderr"
then
  echo 'extra wrong-target version link unexpectedly synchronized' >&2
  exit 1
fi
grep -q 'conflicts with inherited package view' "${wrong_link}/stderr"
test "$(readlink "${wrong_link}/user/Cellar/foo/9.9")" = "${wrong_link}/outside/9.9"
test ! -e "${wrong_link}/user/Cellar/foo/1.0"

# Non-directory, non-link objects are not native kegs and must stop the whole
# transition before a missing inherited version is created.
wrong_object="${work}/wrong-extra-object"
make_case "${wrong_object}"
mkdir -p "${wrong_object}/user/Cellar/foo/2.0"
mark_local_keg "${wrong_object}" "${wrong_object}/user/Cellar/foo/2.0"
printf 'not a keg\n' >"${wrong_object}/user/Cellar/foo/9.9"
activate "${wrong_object}"
if homebrew-overlay-sync --force >"${wrong_object}/stdout" 2>"${wrong_object}/stderr"
then
  echo 'extra non-keg version object unexpectedly synchronized' >&2
  exit 1
fi
grep -q 'invalid version entry in user overlay rack' "${wrong_object}/stderr"
grep -qx 'not a keg' "${wrong_object}/user/Cellar/foo/9.9"
test ! -e "${wrong_object}/user/Cellar/foo/1.0"

# Exact inherited child links are reconstructible from their literal targets.
# They are removed after the lower formula disappears even when view.state has
# been emptied, while the private keg remains untouched.
stale_version="${work}/stale-version"
make_case "${stale_version}"
mkdir -p "${stale_version}/user/Cellar/foo/2.0"
mark_local_keg "${stale_version}" "${stale_version}/user/Cellar/foo/2.0"
activate "${stale_version}"
homebrew-overlay-sync --force
test -L "${stale_version}/user/Cellar/foo/1.0"
rm -rf "${stale_version}/base/Cellar/foo"
rm -f "${stale_version}/base/opt/foo" "${stale_version}/base/var/homebrew/linked/foo"
homebrew-overlay-bump-generation "${stale_version}/base" >/dev/null
: >"${stale_version}/user/var/homebrew/overlay/view.state"
homebrew-overlay-sync --force
test ! -e "${stale_version}/user/Cellar/foo/1.0"
test ! -L "${stale_version}/user/Cellar/foo/1.0"
test -d "${stale_version}/user/Cellar/foo/2.0"

# The same reconstruction removes a stale whole-rack link and its inherited
# opt/linked records after the base formula is deleted and state is lost.
stale_rack="${work}/stale-rack"
make_case "${stale_rack}"
activate "${stale_rack}"
homebrew-overlay-sync --force
test -L "${stale_rack}/user/Cellar/foo"
test -L "${stale_rack}/user/opt/foo"
test -L "${stale_rack}/user/var/homebrew/linked/foo"
rm -rf "${stale_rack}/base/Cellar/foo"
rm -f "${stale_rack}/base/opt/foo" "${stale_rack}/base/var/homebrew/linked/foo"
homebrew-overlay-bump-generation "${stale_rack}/base" >/dev/null
: >"${stale_rack}/user/var/homebrew/overlay/view.state"
homebrew-overlay-sync --force
for path in \
  "${stale_rack}/user/Cellar/foo" \
  "${stale_rack}/user/opt/foo" \
  "${stale_rack}/user/var/homebrew/linked/foo"
do
  test ! -e "${path}"
  test ! -L "${path}"
done

# Native user Cellar oldname/alias links are not overlay-managed. Preserve a
# link that resolves to a real local rack while reconciling unrelated formulae.
local_alias="${work}/local-alias"
make_case "${local_alias}"
mkdir -p "${local_alias}/user/Cellar/bar/3.0"
mark_local_keg "${local_alias}" "${local_alias}/user/Cellar/bar/3.0"
ln -s bar "${local_alias}/user/Cellar/oldbar"
activate "${local_alias}"
homebrew-overlay-sync --force
test -L "${local_alias}/user/Cellar/oldbar"
test "$(readlink "${local_alias}/user/Cellar/oldbar")" = bar
test -d "${local_alias}/user/Cellar/bar/3.0"
test -L "${local_alias}/user/Cellar/foo"
if state_has_relative "${local_alias}/user/var/homebrew/overlay/view.state" 'Cellar/oldbar'
then
  echo 'local Cellar alias unexpectedly became managed state' >&2
  exit 1
fi

printf 'overlay Cellar integrity test: PASS\n'
