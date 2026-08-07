#!/bin/bash
# Crash recovery, managed-state integrity, and inherited-target confinement.
set -euo pipefail

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repo="$(cd "${repo}" && pwd -P)"
# shellcheck source=../../utils/overlay.sh
source "${repo}/Library/Homebrew/utils/overlay.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/homebrew-overlay-sync-integrity.XXXXXX")"
trap 'rm -rf -- "${work}"' EXIT

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

assert_stamp_matches_state() {
  local root="$1"
  local stamp="${root}/user/var/homebrew/overlay/view.stamp"
  local state="${root}/user/var/homebrew/overlay/view.state"
  local -a lines=()
  mapfile -t lines <"${stamp}"
  test "${#lines[@]}" -eq 3
  homebrew-overlay-base-generation-valid "${lines[0]}"
  homebrew-overlay-base-generation-valid "${lines[1]}"
  test "${lines[2]}" = "$(sha256sum "${state}" | awk '{print $1}')"
}

# The desired payload is published before the transaction state. A crash in
# that window leaves a complete desired-only journal, which is safe to replay.
case_desired="${work}/desired-only"
make_case "${case_desired}"
activate "${case_desired}"
homebrew-overlay-sync --force
mkdir -p "${case_desired}/base/Cellar/bar/2.0"
ln -s "../Cellar/bar/2.0" "${case_desired}/base/opt/bar"
ln -s "../../../Cellar/bar/2.0" "${case_desired}/base/var/homebrew/linked/bar"
homebrew-overlay-bump-generation "${case_desired}/base" >/dev/null
transaction_dir="${case_desired}/user/var/homebrew/overlay/sync"
homebrew-overlay-build-view \
  "${case_desired}/user" "${case_desired}/base" "${transaction_dir}/desired"
test ! -e "${transaction_dir}/state"
homebrew-overlay-sync
test -L "${case_desired}/user/Cellar/bar"
test "$(readlink "${case_desired}/user/Cellar/bar")" = "${case_desired}/base/Cellar/bar"
test ! -e "${transaction_dir}/desired"
test ! -e "${transaction_dir}/state"
assert_stamp_matches_state "${case_desired}"

# The unchanged-generation fast path must prove that the committed state file
# and its managed links still match. Missing links are repaired, while an
# unrelated replacement remains a hard conflict.
case_fast="${work}/fast-path"
make_case "${case_fast}"
activate "${case_fast}"
homebrew-overlay-sync --force
rm "${case_fast}/user/Cellar/foo"
homebrew-overlay-sync
test "$(readlink "${case_fast}/user/Cellar/foo")" = "${case_fast}/base/Cellar/foo"
: >"${case_fast}/user/var/homebrew/overlay/view.state"
homebrew-overlay-sync
test -s "${case_fast}/user/var/homebrew/overlay/view.state"
assert_stamp_matches_state "${case_fast}"
wrong_target="${case_fast}/outside/foo"
mkdir -p "${wrong_target}"
rm "${case_fast}/user/Cellar/foo"
ln -s "${wrong_target}" "${case_fast}/user/Cellar/foo"
if homebrew-overlay-sync >"${case_fast}/wrong.out" 2>"${case_fast}/wrong.err"
then
  echo 'wrong managed link target unexpectedly passed the fast path' >&2
  exit 1
fi
grep -q 'user-owned path conflicts with inherited package view' "${case_fast}/wrong.err"
test "$(readlink "${case_fast}/user/Cellar/foo")" = "${wrong_target}"

# A replay payload may name only the exact corresponding path in the configured
# administrator prefix. Matching basenames do not authorize arbitrary targets.
case_target="${work}/target-confinement"
make_case "${case_target}"
activate "${case_target}"
homebrew-overlay-sync --force
outside_target="${case_target}/outside/evil"
mkdir -p "${outside_target}"
printf 'applying\n' >"${case_target}/user/var/homebrew/overlay/sync/state"
printf 'Cellar/evil\0%s\0' "${outside_target}" \
  >"${case_target}/user/var/homebrew/overlay/sync/desired"
if homebrew-overlay-sync >"${case_target}/stdout" 2>"${case_target}/stderr"
then
  echo 'arbitrary synchronization target unexpectedly succeeded' >&2
  exit 1
fi
grep -Eq 'invalid desired overlay package view|unsafe inherited package-view target' "${case_target}/stderr"
test ! -e "${case_target}/user/Cellar/evil"

# State-only journals cannot be recovered because their desired payload is
# absent. They remain an explicit hard error rather than being guessed away.
case_state_only="${work}/state-only"
make_case "${case_state_only}"
activate "${case_state_only}"
homebrew-overlay-sync --force
printf 'applying\n' >"${case_state_only}/user/var/homebrew/overlay/sync/state"
if homebrew-overlay-sync >"${case_state_only}/stdout" 2>"${case_state_only}/stderr"
then
  echo 'state-only synchronization transaction unexpectedly succeeded' >&2
  exit 1
fi
grep -q 'incomplete overlay synchronization transaction' "${case_state_only}/stderr"

# Duplicate, trailing, and hard-linked state cannot authorize link removal.
case_state="${work}/state-validation"
make_case "${case_state}"
activate "${case_state}"
homebrew-overlay-sync --force
state_file="${case_state}/user/var/homebrew/overlay/view.state"
target="${case_state}/base/Cellar/foo"
printf 'Cellar/foo\0%s\0Cellar/foo\0%s\0' "${target}" "${target}" >"${state_file}"
if homebrew-overlay-sync --force >"${case_state}/duplicate.out" 2>"${case_state}/duplicate.err"
then
  echo 'duplicate managed state unexpectedly succeeded' >&2
  exit 1
fi
grep -q 'invalid overlay view state' "${case_state}/duplicate.err"
test -L "${case_state}/user/Cellar/foo"
printf 'Cellar/foo\0%s\0trailing' "${target}" >"${state_file}"
if homebrew-overlay-sync --force >"${case_state}/trailing.out" 2>"${case_state}/trailing.err"
then
  echo 'trailing managed state unexpectedly succeeded' >&2
  exit 1
fi
grep -q 'invalid overlay view state' "${case_state}/trailing.err"
victim="${case_state}/state-victim"
printf 'unchanged-state\n' >"${victim}"
rm "${state_file}"
ln "${victim}" "${state_file}"
if homebrew-overlay-sync >"${case_state}/hardlink.out" 2>"${case_state}/hardlink.err"
then
  echo 'hard-linked managed state unexpectedly succeeded' >&2
  exit 1
fi
grep -q 'invalid overlay view state' "${case_state}/hardlink.err"
grep -qx 'unchanged-state' "${victim}"

printf 'overlay synchronization integrity test: PASS\n'
