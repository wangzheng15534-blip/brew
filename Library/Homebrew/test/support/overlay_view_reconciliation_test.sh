#!/bin/bash
# Fixed-point and target-validation coverage for native Cellar version unions.
set -euo pipefail

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repo="$(cd "${repo}" && pwd -P)"
# shellcheck source=../../utils/overlay.sh
source "${repo}/Library/Homebrew/utils/overlay.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/homebrew-overlay-view.XXXXXX")"
trap 'rm -rf "${work}"' EXIT

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
    "${root}/user/var/homebrew/overlay/transactions/.locks" \
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
  unset HOMEBREW_OVERLAY_OWNER_TRANSACTION_ID
}

state_has_relative() {
  local state="$1"
  local expected="$2"
  python3 - "${state}" "${expected}" <<'PY'
import pathlib
import sys

fields = pathlib.Path(sys.argv[1]).read_bytes().split(b"\0")
entries = dict(zip(fields[0::2], fields[1::2]))
raise SystemExit(0 if sys.argv[2].encode() in entries else 1)
PY
}

# An inherited child is desired on every pass, so repeated reconciliation is a
# fixed point rather than alternately deleting and recreating the link.
fixed="${work}/fixed-point"
make_prefixes "${fixed}"
mkdir -p "${fixed}/user/Cellar/foo/2.0"
printf '%s\n' "$(homebrew-overlay-view-key "${fixed}/base")" > \
  "${fixed}/user/Cellar/foo/2.0/.brew-overlay-base-generation"
activate "${fixed}"
for _ in 1 2 3 4
do
  homebrew-overlay-sync --force
  test -L "${fixed}/user/Cellar/foo/1.0"
  test "$(readlink "${fixed}/user/Cellar/foo/1.0")" = "${fixed}/base/Cellar/foo/1.0"
  state_has_relative "${fixed}/user/var/homebrew/overlay/view.state" 'Cellar/foo/1.0'
done

# An existing symlink with the wrong target is a conflict, not an inherited
# package and not a path that synchronization may silently replace.
wrong="${work}/wrong-target"
make_prefixes "${wrong}"
mkdir -p "${wrong}/user/Cellar/foo" "${wrong}/other/1.0"
ln -s "${wrong}/other/1.0" "${wrong}/user/Cellar/foo/1.0"
activate "${wrong}"
if homebrew-overlay-sync --force >"${wrong}/stdout" 2>"${wrong}/stderr"
then
  echo 'wrong inherited-version target unexpectedly synchronized' >&2
  exit 1
fi
test "$(readlink "${wrong}/user/Cellar/foo/1.0")" = "${wrong}/other/1.0"
grep -q 'conflicts with inherited package view' "${wrong}/stderr"

# Transaction-created inherited children are adopted into managed state. When
# the administrator removes the lower version, synchronization removes the
# now-stale child while retaining the local keg.
removed="${work}/base-removal"
make_prefixes "${removed}"
mkdir -p "${removed}/user/Cellar/foo/2.0"
ln -s "${removed}/base/Cellar/foo/1.0" "${removed}/user/Cellar/foo/1.0"
printf '%s\n' "$(homebrew-overlay-view-key "${removed}/base")" > \
  "${removed}/user/Cellar/foo/2.0/.brew-overlay-base-generation"
activate "${removed}"
homebrew-overlay-sync --force
state_has_relative "${removed}/user/var/homebrew/overlay/view.state" 'Cellar/foo/1.0'
rm -rf "${removed}/base/Cellar/foo/1.0"
homebrew-overlay-bump-generation "${removed}/base" >/dev/null
homebrew-overlay-sync --force
test ! -e "${removed}/user/Cellar/foo/1.0"
test ! -L "${removed}/user/Cellar/foo/1.0"
test -d "${removed}/user/Cellar/foo/2.0"

# A real local keg with the same version deliberately shadows the lower one and
# is excluded from managed inherited state.
shadow="${work}/local-shadow"
make_prefixes "${shadow}"
mkdir -p "${shadow}/user/Cellar/foo/1.0"
printf '%s\n' "$(homebrew-overlay-view-key "${shadow}/base")" > \
  "${shadow}/user/Cellar/foo/1.0/.brew-overlay-base-generation"
activate "${shadow}"
homebrew-overlay-sync --force
test -d "${shadow}/user/Cellar/foo/1.0"
test ! -L "${shadow}/user/Cellar/foo/1.0"
if state_has_relative "${shadow}/user/var/homebrew/overlay/view.state" 'Cellar/foo/1.0'
then
  echo 'real local version unexpectedly became managed inherited state' >&2
  exit 1
fi

# Other object types at a lower-version path are invalid and stop the complete
# view transition before any inherited link is changed.
invalid="${work}/invalid-child"
make_prefixes "${invalid}"
mkdir -p "${invalid}/user/Cellar/foo"
printf 'not a keg\n' >"${invalid}/user/Cellar/foo/1.0"
activate "${invalid}"
if homebrew-overlay-sync --force >"${invalid}/stdout" 2>"${invalid}/stderr"
then
  echo 'invalid version child unexpectedly synchronized' >&2
  exit 1
fi
grep -q 'invalid version entry in user overlay rack' "${invalid}/stderr"

echo 'overlay view reconciliation test: PASS'
