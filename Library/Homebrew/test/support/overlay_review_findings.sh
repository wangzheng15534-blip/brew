#!/bin/bash
# Reproduce shell-level defects found during the native overlay review.
# This intentionally uses `set -u` without `set -e`, matching bin/brew.
set -u

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
source "${repo}/Library/Homebrew/utils/overlay.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/homebrew-native-overlay-review.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
confirmed=0
expected=7

record_defect() {
  local label="$1"
  shift
  if "$@"
  then
    printf 'CONFIRMED: %s\n' "$label"
    confirmed=$((confirmed + 1))
  else
    printf 'NOT REPRODUCED: %s\n' "$label"
  fi
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
    "${user}/Cellar" \
    "${user}/bin" \
    "${user}/etc" \
    "${user}/Frameworks" \
    "${user}/include" \
    "${user}/lib" \
    "${user}/opt" \
    "${user}/sbin" \
    "${user}/share" \
    "${user}/var/homebrew/linked" \
    "${user}/var/homebrew/locks"
}

printf 'CASE 1: active bootstrap reports success after Cellar synchronization fails\n'
case1="${work}/case1"
mkdir -p "${case1}/base/Cellar" "${case1}/user/var/homebrew/locks" \
  "${case1}/user/var/homebrew" "${case1}/user/bin"
ln -s "${case1}/base/Cellar" "${case1}/user/Cellar"
HOMEBREW_PREFIX="${case1}/user"
HOMEBREW_OVERLAY=1
HOMEBREW_OVERLAY_ACTIVE=1
HOMEBREW_OVERLAY_BASE_PREFIX="${case1}/base"
export HOMEBREW_PREFIX HOMEBREW_OVERLAY HOMEBREW_OVERLAY_ACTIVE HOMEBREW_OVERLAY_BASE_PREFIX
homebrew-overlay-bootstrap --cellar >"${case1}/stdout" 2>"${case1}/stderr"
case1_status=$?
printf 'status=%s stderr=%s\n' "${case1_status}" "$(tr '\n' '|' <"${case1}/stderr")"
record_defect 'bootstrap suppresses failed synchronization' test "${case1_status}" -eq 0

printf 'CASE 2: an empty real rack permanently hides the inherited rack\n'
case2="${work}/case2"
make_base_formula "${case2}/base" foo 1.0
make_user_roots "${case2}/user"
HOMEBREW_PREFIX="${case2}/user"
HOMEBREW_OVERLAY_BASE_PREFIX="${case2}/base"
export HOMEBREW_PREFIX HOMEBREW_OVERLAY_BASE_PREFIX
homebrew-overlay-sync >/dev/null 2>&1
rm "${case2}/user/Cellar/foo"
mkdir "${case2}/user/Cellar/foo"
homebrew-overlay-sync >/dev/null 2>&1
printf 'rack_symlink=%s base_keg_visible=%s\n' \
  "$([[ -L "${case2}/user/Cellar/foo" ]] && echo yes || echo no)" \
  "$([[ -d "${case2}/user/Cellar/foo/1.0" ]] && echo yes || echo no)"
record_defect 'empty or interrupted local rack hides base indefinitely' \
  test ! -e "${case2}/user/Cellar/foo/1.0"

printf 'CASE 3: prefix reinitialization overwrites user brew.env settings\n'
case3="${work}/case3"
mkdir -p "${case3}/base/Cellar" "${case3}/repo/bin" "${case3}/home"
printf '#!/bin/bash\n' >"${case3}/repo/bin/brew"
chmod 0755 "${case3}/repo/bin/brew"
HOME="${case3}/home" homebrew-overlay-initialize-prefix \
  "${case3}/base" "${case3}/repo" "${case3}/home/.linuxbrew" >/dev/null
printf 'HOMEBREW_NO_ANALYTICS=1\n' >>"${case3}/home/.linuxbrew/etc/homebrew/brew.env"
HOME="${case3}/home" homebrew-overlay-initialize-prefix \
  "${case3}/base" "${case3}/repo" "${case3}/home/.linuxbrew" >/dev/null
record_defect 'reinitialization destroys unrelated user configuration' \
  sh -c "! grep -q '^HOMEBREW_NO_ANALYTICS=1$' '${case3}/home/.linuxbrew/etc/homebrew/brew.env'"

printf 'CASE 4: an explicit unlink is recreated on the next invocation\n'
case4="${work}/case4"
make_base_formula "${case4}/base" foo 1.0
make_user_roots "${case4}/user"
HOMEBREW_PREFIX="${case4}/user"
HOMEBREW_OVERLAY_BASE_PREFIX="${case4}/base"
export HOMEBREW_PREFIX HOMEBREW_OVERLAY_BASE_PREFIX
homebrew-overlay-sync >/dev/null 2>&1
rm -f "${case4}/user/bin/foo" "${case4}/user/opt/foo" \
  "${case4}/user/var/homebrew/linked/foo"
homebrew-overlay-sync >/dev/null 2>&1
record_defect 'inherited unlink state is not persistent' test -L "${case4}/user/bin/foo"

printf 'CASE 5: unsafe destination parents cause silent partial synchronization\n'
case5="${work}/case5"
make_base_formula "${case5}/base" foo 1.0
make_user_roots "${case5}/user"
rm -rf "${case5}/user/bin"
mkdir -p "${case5}/outside"
ln -s "${case5}/outside" "${case5}/user/bin"
HOMEBREW_PREFIX="${case5}/user"
HOMEBREW_OVERLAY_BASE_PREFIX="${case5}/base"
export HOMEBREW_PREFIX HOMEBREW_OVERLAY_BASE_PREFIX
homebrew-overlay-sync >"${case5}/stdout" 2>"${case5}/stderr"
case5_status=$?
printf 'status=%s projected=%s stderr=%s\n' \
  "${case5_status}" \
  "$([[ -e "${case5}/user/bin/foo" || -L "${case5}/user/bin/foo" ]] && echo yes || echo no)" \
  "$(tr '\n' '|' <"${case5}/stderr")"
record_defect 'synchronizer succeeds while omitting a required inherited link' \
  sh -c "test '${case5_status}' -eq 0 && test ! -e '${case5}/user/bin/foo' && test ! -L '${case5}/user/bin/foo'"

printf 'CASE 6: lexical containment permits deletion through a dot-dot path\n'
case6="${work}/case6"
make_user_roots "${case6}/prefix"
printf 'payload\n' >"${case6}/target"
ln -s "${case6}/target" "${case6}/outside-link"
printf '%s\t%s\n' \
  "${case6}/prefix/../outside-link" "${case6}/target" > \
  "${case6}/prefix/var/homebrew/overlay-links.tsv"
homebrew-overlay-remove-recorded-links \
  "${case6}/prefix" "${case6}/prefix/var/homebrew/overlay-links.tsv"
record_defect 'state cleanup can remove a symlink outside the prefix' \
  test ! -L "${case6}/outside-link"

printf 'CASE 7: a base oldname rack symlink is projected as another installed rack\n'
case7="${work}/case7"
make_user_roots "${case7}/user"
mkdir -p "${case7}/base/Cellar/newname/1.0"
ln -s newname "${case7}/base/Cellar/oldname"
HOMEBREW_PREFIX="${case7}/user"
HOMEBREW_OVERLAY_BASE_PREFIX="${case7}/base"
export HOMEBREW_PREFIX HOMEBREW_OVERLAY_BASE_PREFIX
homebrew-overlay-sync >/dev/null 2>&1
record_defect 'base alias/oldname symlink is exposed as an installed rack' \
  test -L "${case7}/user/Cellar/oldname"

printf 'confirmed=%s expected=%s\n' "${confirmed}" "${expected}"
test "${confirmed}" -eq "${expected}"
