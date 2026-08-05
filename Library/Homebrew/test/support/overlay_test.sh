#!/bin/bash
set -euo pipefail

repository="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repository="$(cd "${repository}" && pwd -P)"
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
mkdir -p "${base}/Caskroom/demo/1.0" "${home}"
printf '#!/bin/sh\nprintf "base-cask\\n"\n' >"${base}/Caskroom/demo/1.0/demo"
chmod 0755 "${base}/Caskroom/demo/1.0/demo"
ln -s "../Caskroom/demo/1.0/demo" "${base}/bin/demo-cask"
ln -s "${repository}/bin/brew" "${base}/bin/brew"
# A Cellar oldname is metadata, not another independently installed formula.
ln -s foo "${base}/Cellar/foo-old"
printf 'generation-1\n' >"${base}/var/homebrew/overlay-generation"

# A user brew.env is user-owned and must survive initialization unchanged.
mkdir -p "${user_prefix}/etc/homebrew"
printf 'HOMEBREW_NO_ANALYTICS=1\n' >"${user_prefix}/etc/homebrew/brew.env"
actual_prefix="$(HOME="${home}" homebrew-overlay-initialize-prefix \
  "${base}" "${repository}" "${user_prefix}")"

test "${actual_prefix}" = "${user_prefix}"
test -d "${user_prefix}/Cellar"
test ! -L "${user_prefix}/Cellar"
test -d "${user_prefix}/Caskroom"
test -L "${user_prefix}/bin/brew"
test "$(readlink "${user_prefix}/bin/brew")" = "${repository}/bin/brew"
test "$(stat -c '%a' "${user_prefix}/etc/homebrew/overlay.env")" = 600
grep -qx 'HOMEBREW_NO_ANALYTICS=1' "${user_prefix}/etc/homebrew/brew.env"
grep -qx "HOMEBREW_OVERLAY_BASE_PREFIX=${base}" "${user_prefix}/etc/homebrew/overlay.env"
grep -qx "HOMEBREW_OVERLAY_USER_PREFIX=${user_prefix}" "${user_prefix}/etc/homebrew/overlay.env"
grep -qx 'HOMEBREW_NO_AUTO_UPDATE=1' "${user_prefix}/etc/homebrew/overlay.env"

export HOME="${home}"
export HOMEBREW_PREFIX="${user_prefix}"
export HOMEBREW_OVERLAY=1
export HOMEBREW_OVERLAY_ACTIVE=1
export HOMEBREW_OVERLAY_BASE_PREFIX="${base}"

homebrew-overlay-sync --force
base_generation="$(bash "${repository}/Library/Homebrew/utils/overlay.sh" --base-generation)"
homebrew-overlay-base-generation-valid "${base_generation}"

test -L "${user_prefix}/Cellar/foo"
test "$(readlink "${user_prefix}/Cellar/foo")" = "${base}/Cellar/foo"
test -L "${user_prefix}/Cellar/baseonly"
test -L "${user_prefix}/opt/foo"
test "$(readlink "${user_prefix}/opt/foo")" = "${base}/opt/foo"
test -L "${user_prefix}/var/homebrew/linked/foo"
test ! -e "${user_prefix}/Cellar/foo-old"
test ! -L "${user_prefix}/Cellar/foo-old"
# Cask artifacts and the administrator link tree are deliberately not copied.
test ! -e "${user_prefix}/bin/foo"
test ! -e "${user_prefix}/bin/demo-cask"

# shellenv composes two native prefixes: user first, administrator second.
# This provides executable fallback without recursive link projection.
export HOMEBREW_CELLAR="${user_prefix}/Cellar"
export HOMEBREW_REPOSITORY="${repository}"
export HOMEBREW_PATH="/usr/bin:/bin"
export HOMEBREW_MACOS=""
export HOMEBREW_MACOS_VERSION_NUMERIC=0
export SHELL=/bin/bash
# shellcheck source=../../cmd/shellenv.sh
source "${repository}/Library/Homebrew/cmd/shellenv.sh"
shellenv_output="$(homebrew-shellenv bash)"
grep -Fq "export PATH=\"${user_prefix}/bin:${user_prefix}/sbin:${base}/bin:${base}/sbin" <<<"${shellenv_output}"
grep -Fq "export INFOPATH=\"${user_prefix}/share/info:${base}/share/info:" <<<"${shellenv_output}"
test "$(env PATH="${user_prefix}/bin:${user_prefix}/sbin:${base}/bin:${base}/sbin:/usr/bin:/bin" foo)" = base-foo
launcher_cellar="$(env \
  -u HOMEBREW_OVERLAY_ACTIVE \
  -u HOMEBREW_OVERLAY_USER_PREFIX \
  HOME="${home}" \
  HOMEBREW_OVERLAY=1 \
  HOMEBREW_OVERLAY_FORCE=1 \
  HOMEBREW_OVERLAY_BASE_PREFIX="${base}" \
  "${base}/bin/brew" --cellar)"
test "${launcher_cellar}" = "${user_prefix}/Cellar"

# A real local rack forms a version union with missing base versions, while
# local opt/link records shadow the administrator records.
rm "${user_prefix}/Cellar/foo"
mkdir -p "${user_prefix}/Cellar/foo/2.0/bin"
printf '#!/bin/sh\nprintf "user-foo\\n"\n' >"${user_prefix}/Cellar/foo/2.0/bin/foo"
chmod 0755 "${user_prefix}/Cellar/foo/2.0/bin/foo"
printf '%s\n' "${base_generation}" >"${user_prefix}/Cellar/foo/2.0/.brew-overlay-base-generation"
homebrew-overlay-sync --force

test ! -L "${user_prefix}/Cellar/foo"
test -d "${user_prefix}/Cellar/foo/2.0"
test -L "${user_prefix}/Cellar/foo/1.0"
test "$(readlink "${user_prefix}/Cellar/foo/1.0")" = "${base}/Cellar/foo/1.0"
test ! -e "${user_prefix}/opt/foo"
test ! -e "${user_prefix}/var/homebrew/linked/foo"
ln -s "../Cellar/foo/2.0" "${user_prefix}/opt/foo"
ln -s "../../../Cellar/foo/2.0" "${user_prefix}/var/homebrew/linked/foo"
homebrew-overlay-sync --force
test "$(readlink "${user_prefix}/opt/foo")" = "../Cellar/foo/2.0"

# Every real local keg records the administrator generation it was built
# against. Missing or stale markers are surfaced without disabling the prefix.
mkdir -p "${user_prefix}/Cellar/localonly/1.0"
if ! homebrew-overlay-sync --force >"${work}/missing-generation.out" 2>"${work}/missing-generation.err"
then
  echo "generation drift reporting unexpectedly failed synchronization" >&2
  exit 1
fi
grep -q 'administrator Homebrew base changed' "${work}/missing-generation.err"
test -s "${user_prefix}/var/homebrew/overlay/base-drift.state"
rm -rf "${user_prefix}/Cellar/localonly"
homebrew-overlay-sync --force
test ! -e "${user_prefix}/var/homebrew/overlay/base-drift.state"

printf 'generation-2\n' >"${base}/var/homebrew/overlay-generation"
new_base_generation="$(bash "${repository}/Library/Homebrew/utils/overlay.sh" --base-generation)"
homebrew-overlay-base-generation-valid "${new_base_generation}"
test "${new_base_generation}" != "${base_generation}"
homebrew-overlay-sync --force 2>"${work}/stale-generation.err"
grep -q 'administrator Homebrew base changed' "${work}/stale-generation.err"
test -s "${user_prefix}/var/homebrew/overlay/base-drift.state"
printf '%s\n' "${new_base_generation}" >"${user_prefix}/Cellar/foo/2.0/.brew-overlay-base-generation"
homebrew-overlay-sync --force
test ! -e "${user_prefix}/var/homebrew/overlay/base-drift.state"
base_generation="${new_base_generation}"

outside_generation="${work}/outside-generation"
printf 'unchanged\n' >"${outside_generation}"
rm "${user_prefix}/Cellar/foo/2.0/.brew-overlay-base-generation"
ln -s "${outside_generation}" "${user_prefix}/Cellar/foo/2.0/.brew-overlay-base-generation"
if homebrew-overlay-sync --force >"${work}/unsafe-generation.out" 2>"${work}/unsafe-generation.err"
then
  echo "unsafe base-generation marker unexpectedly succeeded" >&2
  exit 1
fi
grep -q 'unsafe base-generation marker' "${work}/unsafe-generation.err"
grep -qx 'unchanged' "${outside_generation}"
rm "${user_prefix}/Cellar/foo/2.0/.brew-overlay-base-generation"
printf '%s\n' "${base_generation}" >"${user_prefix}/Cellar/foo/2.0/.brew-overlay-base-generation"
homebrew-overlay-sync --force

# An empty real rack cannot hide the base indefinitely; it receives inherited
# version links on the next synchronization.
rm "${user_prefix}/Cellar/baseonly"
mkdir "${user_prefix}/Cellar/baseonly"
homebrew-overlay-sync --force
test -L "${user_prefix}/Cellar/baseonly/1.0"
test -d "${user_prefix}/Cellar/baseonly/1.0"

# A corrupt relative state path is rejected and cannot escape the prefix.
outside="${work}/outside"
printf 'payload\n' >"${outside}"
ln -s "${outside}" "${work}/outside-link"
printf '../outside-link\0%s\0' "${outside}" >"$(homebrew-overlay-state-file)"
if homebrew-overlay-sync --force >"${work}/corrupt.out" 2>"${work}/corrupt.err"
then
  echo "corrupt overlay state unexpectedly succeeded" >&2
  exit 1
fi
test -L "${work}/outside-link"
grep -q 'invalid overlay view state' "${work}/corrupt.err"
rm -f "$(homebrew-overlay-state-file)"
homebrew-overlay-sync --force

# Unsafe directory parents are hard failures and nothing is written through the
# symlink. Restore the real directory and recover normally.
rm -rf "${user_prefix}/opt"
mkdir "${work}/outside-opt"
ln -s "${work}/outside-opt" "${user_prefix}/opt"
if homebrew-overlay-sync --force >"${work}/unsafe.out" 2>"${work}/unsafe.err"
then
  echo "unsafe overlay parent unexpectedly succeeded" >&2
  exit 1
fi
test ! -e "${work}/outside-opt/baseonly"
grep -q 'unsafe parent blocks inherited package view' "${work}/unsafe.err"
rm "${user_prefix}/opt"
mkdir "${user_prefix}/opt"
homebrew-overlay-sync --force

# Bootstrap must propagate synchronization failures under bin/brew's set -u
# execution model.
rm -rf "${user_prefix}/Cellar"
ln -s "${base}/Cellar" "${user_prefix}/Cellar"
if homebrew-overlay-bootstrap --cellar >"${work}/bootstrap.out" 2>"${work}/bootstrap.err"
then
  echo "bootstrap unexpectedly suppressed a synchronization failure" >&2
  exit 1
fi
grep -q 'user overlay Cellar is not a real directory' "${work}/bootstrap.err"
rm "${user_prefix}/Cellar"
mkdir "${user_prefix}/Cellar"
rm -f "${user_prefix}/opt/foo" "${user_prefix}/var/homebrew/linked/foo"
homebrew-overlay-sync --force

# The default fallback is one native prefix, not an env/package-store layout.
test "$(HOME="${home}" homebrew-overlay-default-user-prefix)" = "${home}/.linuxbrew"
test ! -e "${home}/.local/share/homebrew/envs"
test ! -e "${home}/.local/share/homebrew/pkgs"

printf 'native overlay shell test: PASS\n'
