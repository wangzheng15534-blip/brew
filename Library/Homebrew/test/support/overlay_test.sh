#!/bin/bash
set -euo pipefail

repository="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
# shellcheck source=../../utils/overlay.sh
source "${repository}/Library/Homebrew/utils/overlay.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/homebrew-overlay-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT

base="${work}/base"
shared="${work}/shared"
home="${work}/home"
environments="${home}/.local/share/homebrew/envs"
packages="${home}/.local/share/homebrew/pkgs"

create_formula() {
  local prefix="$1"
  local name="$2"
  local version="$3"
  local marker="$4"

  mkdir -p "${prefix}/Cellar/${name}/${version}/bin" \
    "${prefix}/bin" \
    "${prefix}/opt" \
    "${prefix}/var/homebrew/linked"
  printf '#!/bin/sh\nprintf "%%s\\n" %q\n' "${marker}" >"${prefix}/Cellar/${name}/${version}/bin/${name}"
  chmod 0755 "${prefix}/Cellar/${name}/${version}/bin/${name}"
  ln -s "../Cellar/${name}/${version}/bin/${name}" "${prefix}/bin/${name}"
  ln -s "../Cellar/${name}/${version}" "${prefix}/opt/${name}"
  ln -s "${prefix}/Cellar/${name}/${version}" "${prefix}/var/homebrew/linked/${name}"
}

create_formula "${base}" foo 1.0 base-foo
create_formula "${base}" baseonly 1.0 base-only
create_formula "${shared}" foo 1.5 shared-foo
create_formula "${shared}" sharedonly 1.0 shared-only
mkdir -p "${repository}/bin" "${home}"

environment_prefix="$(HOME="${home}" homebrew-overlay-initialize-environment \
  "${base}" \
  "${repository}" \
  default \
  "${environments}" \
  "${packages}" \
  "${shared}:${base}")"

export HOME="${home}"
export HOMEBREW_PREFIX="${environment_prefix}"
export HOMEBREW_OVERLAY_ACTIVE=1
export HOMEBREW_OVERLAY_PARENT_PREFIXES="${shared}:${base}"
export HOMEBREW_OVERLAY_USER_CELLAR="${packages}/default/Cellar"

homebrew-overlay-sync

test -L "${environment_prefix}/Cellar"
test "$(readlink "${environment_prefix}/Cellar")" = "${packages}/default/Cellar"
test "$(readlink "${packages}/default/Cellar/foo")" = "${shared}/Cellar/foo"
test "$(readlink "${packages}/default/Cellar/sharedonly")" = "${shared}/Cellar/sharedonly"
test "$(readlink "${packages}/default/Cellar/baseonly")" = "${base}/Cellar/baseonly"
test "$(readlink "${environment_prefix}/bin/foo")" = "${shared}/bin/foo"
test "$(readlink "${environment_prefix}/opt/foo")" = "../Cellar/foo/1.5"
test "$(readlink "${environment_prefix}/var/homebrew/linked/foo")" = \
  "${environment_prefix}/Cellar/foo/1.5"
test "$(stat -c '%a' "${environment_prefix}/etc/homebrew/brew.env")" = 600
grep -qx 'HOMEBREW_NO_AUTO_UPDATE=1' "${environment_prefix}/etc/homebrew/brew.env"

# Replacing an inherited rack with a real user rack must shadow every parent.
rm "${packages}/default/Cellar/foo"
mkdir -p "${packages}/default/Cellar/foo/2.0/bin"
printf '#!/bin/sh\nprintf "user-foo\\n"\n' >"${packages}/default/Cellar/foo/2.0/bin/foo"
chmod 0755 "${packages}/default/Cellar/foo/2.0/bin/foo"

# Simulate the links created by Keg#link for the user realization.
rm "${environment_prefix}/bin/foo" \
  "${environment_prefix}/opt/foo" \
  "${environment_prefix}/var/homebrew/linked/foo"
ln -s "../Cellar/foo/2.0/bin/foo" "${environment_prefix}/bin/foo"
ln -s "../Cellar/foo/2.0" "${environment_prefix}/opt/foo"
ln -s "${environment_prefix}/Cellar/foo/2.0" "${environment_prefix}/var/homebrew/linked/foo"

homebrew-overlay-sync

test ! -L "${packages}/default/Cellar/foo"
test -d "${environment_prefix}/Cellar/foo/2.0"
test "$(readlink "${environment_prefix}/bin/foo")" = "../Cellar/foo/2.0/bin/foo"
test "$(readlink "${environment_prefix}/opt/foo")" = "../Cellar/foo/2.0"
test "$(readlink "${environment_prefix}/var/homebrew/linked/foo")" = \
  "${environment_prefix}/Cellar/foo/2.0"

# Homebrew removes empty opt and linked-keg directories during uninstall.
# A later overlay sync must recreate them before restoring inherited links.
rm -rf "${environment_prefix}/opt" "${environment_prefix}/var/homebrew/linked"
homebrew-overlay-sync
test -d "${environment_prefix}/opt"
test -d "${environment_prefix}/var/homebrew/linked"
test -L "${environment_prefix}/opt/baseonly"
test -L "${environment_prefix}/var/homebrew/linked/baseonly"

# A user replacement must not be removed just because an older manifest listed
# the same destination with an inherited target.
replacement="${work}/replacement"
mkdir -p "${replacement}"
rm "${environment_prefix}/bin/sharedonly"
ln -s "${replacement}" "${environment_prefix}/bin/sharedonly"
homebrew-overlay-sync
test "$(readlink "${environment_prefix}/bin/sharedonly")" = "${replacement}"

# Syncing only writes beneath the user roots.
test "$("${base}/bin/foo")" = base-foo
test "$("${shared}/bin/foo")" = shared-foo

printf 'overlay shell test: PASS\n'
