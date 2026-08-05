#!/bin/bash
# Regression coverage for defects identified by the rigorous native-overlay review.
set -euo pipefail

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repo="$(cd "${repo}" && pwd -P)"
# shellcheck source=../../utils/overlay.sh
source "${repo}/Library/Homebrew/utils/overlay.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/homebrew-native-overlay-regression.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
passed=0
expected=7

record_pass() {
  printf 'PASS: %s\n' "$1"
  passed=$((passed + 1))
}

make_base_formula() {
  local base="$1"
  local name="$2"
  local version="$3"
  mkdir -p \
    "${base}/Cellar/${name}/${version}/bin" \
    "${base}/bin" \
    "${base}/opt" \
    "${base}/var/homebrew/linked"
  printf '#!/bin/sh\nprintf "base-%s\\n"\n' "${name}" > \
    "${base}/Cellar/${name}/${version}/bin/${name}"
  chmod 0755 "${base}/Cellar/${name}/${version}/bin/${name}"
  ln -s "../Cellar/${name}/${version}/bin/${name}" "${base}/bin/${name}"
  ln -s "../Cellar/${name}/${version}" "${base}/opt/${name}"
  ln -s "../../../Cellar/${name}/${version}" "${base}/var/homebrew/linked/${name}"
}

make_user_roots() {
  local user="$1"
  mkdir -p \
    "${user}/Cellar" "${user}/bin" "${user}/etc/homebrew" \
    "${user}/Frameworks" "${user}/include" "${user}/lib" "${user}/opt" \
    "${user}/sbin" "${user}/share" "${user}/var/homebrew/linked" \
    "${user}/var/homebrew/locks" "${user}/var/homebrew/overlay/transactions" \
    "${user}/var/homebrew/overlay/sync"
}

printf 'CASE 1: active bootstrap propagates Cellar synchronization failure\n'
case1="${work}/case1"
mkdir -p "${case1}/base/Cellar"
make_user_roots "${case1}/user"
rm -rf "${case1}/user/Cellar"
ln -s "${case1}/base/Cellar" "${case1}/user/Cellar"
export HOMEBREW_PREFIX="${case1}/user"
export HOMEBREW_OVERLAY=1
export HOMEBREW_OVERLAY_ACTIVE=1
export HOMEBREW_OVERLAY_BASE_PREFIX="${case1}/base"
if homebrew-overlay-bootstrap --cellar >"${case1}/stdout" 2>"${case1}/stderr"
then
  echo 'bootstrap suppressed synchronization failure' >&2
  exit 1
fi
grep -q 'user overlay Cellar is not a real directory' "${case1}/stderr"
record_pass 'bootstrap propagates failed synchronization'

printf 'CASE 2: an empty real rack receives inherited versions\n'
case2="${work}/case2"
make_base_formula "${case2}/base" foo 1.0
make_user_roots "${case2}/user"
export HOMEBREW_PREFIX="${case2}/user"
export HOMEBREW_OVERLAY_BASE_PREFIX="${case2}/base"
homebrew-overlay-sync --force
rm "${case2}/user/Cellar/foo"
mkdir "${case2}/user/Cellar/foo"
homebrew-overlay-sync --force
test -L "${case2}/user/Cellar/foo/1.0"
test -d "${case2}/user/Cellar/foo/1.0"
record_pass 'empty/interrupted local rack no longer hides base'

printf 'CASE 3: initialization preserves user brew.env\n'
case3="${work}/case3"
mkdir -p "${case3}/base/Cellar" "${case3}/home/.linuxbrew/etc/homebrew"
printf '#!/bin/bash\n' >"${case3}/brew"
chmod 0755 "${case3}/brew"
mkdir -p "${case3}/repo/bin"
cp "${case3}/brew" "${case3}/repo/bin/brew"
printf 'HOMEBREW_NO_ANALYTICS=1\n' >"${case3}/home/.linuxbrew/etc/homebrew/brew.env"
HOME="${case3}/home" homebrew-overlay-initialize-prefix \
  "${case3}/base" "${case3}/repo" "${case3}/home/.linuxbrew" >/dev/null
HOME="${case3}/home" homebrew-overlay-initialize-prefix \
  "${case3}/base" "${case3}/repo" "${case3}/home/.linuxbrew" >/dev/null
grep -qx 'HOMEBREW_NO_ANALYTICS=1' "${case3}/home/.linuxbrew/etc/homebrew/brew.env"
test -f "${case3}/home/.linuxbrew/etc/homebrew/overlay.env"
record_pass 'reinitialization preserves unrelated user configuration'

printf 'CASE 4: inherited executable fallback does not require prefix projection\n'
case4="${work}/case4"
make_base_formula "${case4}/base" foo 1.0
make_user_roots "${case4}/user"
export HOMEBREW_PREFIX="${case4}/user"
export HOMEBREW_OVERLAY_BASE_PREFIX="${case4}/base"
homebrew-overlay-sync --force
test ! -e "${case4}/user/bin/foo"
test "$(env PATH="${case4}/user/bin:${case4}/base/bin:/usr/bin:/bin" foo)" = base-foo
record_pass 'lower executable stays in native base prefix and works through PATH fallback'

printf 'CASE 5: unsafe destination parent is a hard failure\n'
case5="${work}/case5"
make_base_formula "${case5}/base" foo 1.0
make_user_roots "${case5}/user"
rm -rf "${case5}/user/opt"
mkdir "${case5}/outside"
ln -s "${case5}/outside" "${case5}/user/opt"
export HOMEBREW_PREFIX="${case5}/user"
export HOMEBREW_OVERLAY_BASE_PREFIX="${case5}/base"
if homebrew-overlay-sync --force >"${case5}/stdout" 2>"${case5}/stderr"
then
  echo 'unsafe destination parent was silently skipped' >&2
  exit 1
fi
test ! -e "${case5}/outside/foo"
grep -q 'unsafe parent blocks inherited package view' "${case5}/stderr"
record_pass 'unsafe destination parent stops synchronization'

printf 'CASE 6: state paths are relative, normalized, and confined\n'
case6="${work}/case6"
make_base_formula "${case6}/base" foo 1.0
make_user_roots "${case6}/user"
printf 'payload\n' >"${case6}/target"
ln -s "${case6}/target" "${case6}/outside-link"
printf '../outside-link\0%s\0' "${case6}/target" >"${case6}/user/var/homebrew/overlay/view.state"
export HOMEBREW_PREFIX="${case6}/user"
export HOMEBREW_OVERLAY_BASE_PREFIX="${case6}/base"
if homebrew-overlay-sync --force >"${case6}/stdout" 2>"${case6}/stderr"
then
  echo 'path traversal state unexpectedly succeeded' >&2
  exit 1
fi
test -L "${case6}/outside-link"
grep -q 'invalid overlay view state' "${case6}/stderr"
record_pass 'state cleanup cannot escape the active prefix'

printf 'CASE 7: administrator Cellar oldname symlinks are not projected as racks\n'
case7="${work}/case7"
make_user_roots "${case7}/user"
mkdir -p "${case7}/base/Cellar/newname/1.0" "${case7}/base/opt" "${case7}/base/var/homebrew/linked"
ln -s newname "${case7}/base/Cellar/oldname"
export HOMEBREW_PREFIX="${case7}/user"
export HOMEBREW_OVERLAY_BASE_PREFIX="${case7}/base"
homebrew-overlay-sync --force
test ! -e "${case7}/user/Cellar/oldname"
test ! -L "${case7}/user/Cellar/oldname"
record_pass 'base alias/oldname symlink is not exposed as an installed rack'

printf 'passed=%s expected=%s\n' "${passed}" "${expected}"
test "${passed}" -eq "${expected}"
