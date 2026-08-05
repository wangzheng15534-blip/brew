#!/bin/bash
set -euo pipefail

repository="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
# shellcheck source=../../utils/overlay.sh
source "${repository}/Library/Homebrew/utils/overlay.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/homebrew-overlay-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT

base="${work}/home/linuxbrew/.linuxbrew"
home="${work}/home/developer"
user_prefix="${home}/.linuxbrew"

create_formula() {
  local prefix="$1"
  local name="$2"
  local version="$3"
  local marker="$4"

  mkdir -p \
    "${prefix}/Cellar/${name}/${version}/bin" \
    "${prefix}/bin" \
    "${prefix}/opt" \
    "${prefix}/var/homebrew/linked"
  printf '#!/bin/sh\nprintf "%%s\\n" %q\n' "${marker}" >"${prefix}/Cellar/${name}/${version}/bin/${name}"
  chmod 0755 "${prefix}/Cellar/${name}/${version}/bin/${name}"
  ln -s "../Cellar/${name}/${version}/bin/${name}" "${prefix}/bin/${name}"
  ln -s "../Cellar/${name}/${version}" "${prefix}/opt/${name}"
  ln -s "../../../Cellar/${name}/${version}" "${prefix}/var/homebrew/linked/${name}"
}

create_formula "${base}" foo 1.0 base-foo
create_formula "${base}" baseonly 1.0 base-only
mkdir -p "${base}/Caskroom/demo/1.0"
printf '#!/bin/sh\nprintf "base-cask\\n"\n' >"${base}/Caskroom/demo/1.0/demo"
chmod 0755 "${base}/Caskroom/demo/1.0/demo"
ln -s "../Caskroom/demo/1.0/demo" "${base}/bin/demo-cask"
mkdir -p "${repository}/bin" "${home}"
ln -s "${repository}/bin/brew" "${base}/bin/brew"

actual_prefix="$(HOME="${home}" homebrew-overlay-initialize-prefix \
  "${base}" \
  "${repository}" \
  "${user_prefix}")"

test "${actual_prefix}" = "${user_prefix}"
test -d "${user_prefix}/Cellar"
test ! -L "${user_prefix}/Cellar"
test -d "${user_prefix}/Caskroom"
test -L "${user_prefix}/bin/brew"
test "$(readlink "${user_prefix}/bin/brew")" = "${repository}/bin/brew"
test "$(stat -c '%a' "${user_prefix}/etc/homebrew/brew.env")" = 600
grep -qx "HOMEBREW_OVERLAY_BASE_PREFIX=${base}" "${user_prefix}/etc/homebrew/brew.env"
grep -qx "HOMEBREW_OVERLAY_USER_PREFIX=${user_prefix}" "${user_prefix}/etc/homebrew/brew.env"
grep -qx 'HOMEBREW_NO_AUTO_UPDATE=1' "${user_prefix}/etc/homebrew/brew.env"

export HOME="${home}"
export HOMEBREW_PREFIX="${user_prefix}"
export HOMEBREW_OVERLAY_ACTIVE=1
export HOMEBREW_OVERLAY_BASE_PREFIX="${base}"

homebrew-overlay-sync

test -L "${user_prefix}/Cellar/foo"
test "$(readlink "${user_prefix}/Cellar/foo")" = "${base}/Cellar/foo"
test -L "${user_prefix}/Cellar/baseonly"
test "$(readlink "${user_prefix}/bin/foo")" = "../Cellar/foo/1.0/bin/foo"
test "$(readlink "${user_prefix}/opt/foo")" = "../Cellar/foo/1.0"
test "$(readlink "${user_prefix}/var/homebrew/linked/foo")" = \
  "../../../Cellar/foo/1.0"
test "$("${user_prefix}/bin/foo")" = base-foo
test ! -e "${user_prefix}/bin/demo-cask"
test ! -L "${user_prefix}/bin/demo-cask"

# A real user rack shadows the administrator rack and its inherited links.
rm "${user_prefix}/Cellar/foo"
mkdir -p "${user_prefix}/Cellar/foo/2.0/bin"
printf '#!/bin/sh\nprintf "user-foo\\n"\n' >"${user_prefix}/Cellar/foo/2.0/bin/foo"
chmod 0755 "${user_prefix}/Cellar/foo/2.0/bin/foo"
rm "${user_prefix}/bin/foo" \
  "${user_prefix}/opt/foo" \
  "${user_prefix}/var/homebrew/linked/foo"
ln -s "../Cellar/foo/2.0/bin/foo" "${user_prefix}/bin/foo"
ln -s "../Cellar/foo/2.0" "${user_prefix}/opt/foo"
ln -s "../../../Cellar/foo/2.0" "${user_prefix}/var/homebrew/linked/foo"

homebrew-overlay-sync

test ! -L "${user_prefix}/Cellar/foo"
test -d "${user_prefix}/Cellar/foo/2.0"
test "$(readlink "${user_prefix}/bin/foo")" = "../Cellar/foo/2.0/bin/foo"
test "$("${user_prefix}/bin/foo")" = user-foo

# Homebrew may remove empty native link directories during uninstall. Sync must
# recreate them before restoring inherited links.
rm -rf "${user_prefix}/opt" "${user_prefix}/var/homebrew/linked"
homebrew-overlay-sync
test -d "${user_prefix}/opt"
test -d "${user_prefix}/var/homebrew/linked"
test -L "${user_prefix}/opt/baseonly"
test -L "${user_prefix}/var/homebrew/linked/baseonly"

# A user replacement must not be removed merely because an older overlay state
# recorded an inherited target at the same path.
replacement="${work}/replacement"
printf 'replacement\n' >"${replacement}"
rm "${user_prefix}/bin/baseonly"
ln -s "${replacement}" "${user_prefix}/bin/baseonly"
homebrew-overlay-sync
test "$(readlink "${user_prefix}/bin/baseonly")" = "${replacement}"

# Removing a base package removes only its inherited local rack/link on sync.
rm "${base}/bin/baseonly" \
  "${base}/opt/baseonly" \
  "${base}/var/homebrew/linked/baseonly"
rm -rf "${base}/Cellar/baseonly"
rm "${user_prefix}/bin/baseonly"
homebrew-overlay-sync
test ! -e "${user_prefix}/Cellar/baseonly"
test ! -e "${user_prefix}/opt/baseonly"
test ! -e "${user_prefix}/var/homebrew/linked/baseonly"

# Synchronization never modifies the administrator prefix.
test "$("${base}/bin/foo")" = base-foo

# The actual admin launcher re-execs the native user-prefix launcher.
launcher_cellar="$(env \
  -u HOMEBREW_OVERLAY_ACTIVE \
  -u HOMEBREW_OVERLAY_BASE_PREFIX \
  -u HOMEBREW_OVERLAY_USER_PREFIX \
  HOME="${home}" \
  HOMEBREW_OVERLAY=1 \
  HOMEBREW_OVERLAY_FORCE=1 \
  "${base}/bin/brew" --cellar)"
test "${launcher_cellar}" = "${user_prefix}/Cellar"

# The default fallback is one native prefix, not an env/package-store layout.
test "$(HOME="${home}" homebrew-overlay-default-user-prefix)" = "${home}/.linuxbrew"
test ! -e "${home}/.local/share/homebrew/envs"
test ! -e "${home}/.local/share/homebrew/pkgs"

printf 'native overlay shell test: PASS\n'
