#!/bin/bash
# Markerless rack recovery requires literal inherited targets, not aliases.
set -euo pipefail

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repo="$(cd "${repo}" && pwd -P)"
# shellcheck source=../../utils/overlay.sh
source "${repo}/Library/Homebrew/utils/overlay.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/homebrew-overlay-rack-exactness.XXXXXX")"
trap 'rm -rf -- "${work}"' EXIT

make_case() {
  local root="$1"
  mkdir -p \
    "${root}/base/Cellar/foo/2.0/bin" "${root}/base/opt" "${root}/base/var/homebrew/linked" \
    "${root}/user/Cellar" "${root}/user/bin" "${root}/user/sbin" "${root}/user/include" \
    "${root}/user/lib" "${root}/user/share" "${root}/user/Frameworks" "${root}/user/opt" \
    "${root}/user/var/homebrew/linked" "${root}/user/var/homebrew/overlay/transactions/.locks" \
    "${root}/user/var/homebrew/overlay/sync"
  printf 'base\n' >"${root}/base/Cellar/foo/2.0/bin/foo"
  ln -s '../Cellar/foo/2.0' "${root}/base/opt/foo"
  ln -s '../../../Cellar/foo/2.0' "${root}/base/var/homebrew/linked/foo"
  ln -s "${root}/base/Cellar/foo" "${root}/user/Cellar/foo"
  homebrew-overlay-ensure-generation "${root}/base"
  homebrew-overlay-ensure-generation "${root}/user"
}

write_journal() {
  local root="$1"
  local id="$2"
  local state="$3"
  local tx="${root}/user/var/homebrew/overlay/transactions/${id}"
  mkdir -p "${tx}"
  printf 'foo\n' >"${tx}/formula"
  printf '3.0\n' >"${tx}/version"
  homebrew-overlay-read-generation "${root}/base" >"${tx}/base_generation"
  printf '%s\n' "${state}" >"${tx}/state"
}

activate() {
  local root="$1"
  export HOMEBREW_PREFIX="${root}/user"
  export HOMEBREW_OVERLAY_BASE_PREFIX="${root}/base"
  export HOMEBREW_OVERLAY=1
  export HOMEBREW_OVERLAY_ACTIVE=1
  unset HOMEBREW_OVERLAY_MUTATION_OWNER HOMEBREW_OVERLAY_FINALIZE_MUTATION \
    HOMEBREW_OVERLAY_MUTATION_LOCK_FD HOMEBREW_OVERLAY_OWNER_TRANSACTION_ID \
    HOMEBREW_OVERLAY_OWNER_TRANSACTION_LOCK_FD
}

# A whole-rack alias resolves to the administrator rack, but it is not the
# literal link that synchronization publishes and cannot prove completed cleanup.
rack_alias="${work}/rack-alias"
make_case "${rack_alias}"
rm "${rack_alias}/user/Cellar/foo"
ln -s "${rack_alias}/base/Cellar/../Cellar/foo" "${rack_alias}/user/Cellar/foo"
write_journal "${rack_alias}" txn-rack-alias rolling-back
activate "${rack_alias}"
if homebrew-overlay-sync --force >"${rack_alias}/stdout" 2>"${rack_alias}/stderr"
then
  echo 'canonical whole-rack alias unexpectedly authorized cleanup' >&2
  exit 1
fi
grep -Eq 'does not own either recovery rack|did not restore an exact inherited rack' "${rack_alias}/stderr"
test -d "${rack_alias}/user/var/homebrew/overlay/transactions/txn-rack-alias"
test "$(readlink "${rack_alias}/user/Cellar/foo")" = \
  "${rack_alias}/base/Cellar/../Cellar/foo"

# A version-union alias is rejected for the same reason, even though readlink -f
# reaches the same administrator version.
version_alias="${work}/version-alias"
make_case "${version_alias}"
rm "${version_alias}/user/Cellar/foo"
mkdir "${version_alias}/user/Cellar/foo"
ln -s "${version_alias}/base/Cellar/foo/../foo/2.0" \
  "${version_alias}/user/Cellar/foo/2.0"
write_journal "${version_alias}" txn-version-alias recovering-cleanup
activate "${version_alias}"
if homebrew-overlay-sync --force >"${version_alias}/stdout" 2>"${version_alias}/stderr"
then
  echo 'canonical version alias unexpectedly authorized cleanup' >&2
  exit 1
fi
grep -Eq 'has no failed rack to clean|did not restore an exact inherited rack' "${version_alias}/stderr"
test -d "${version_alias}/user/var/homebrew/overlay/transactions/txn-version-alias"
test "$(readlink "${version_alias}/user/Cellar/foo/2.0")" = \
  "${version_alias}/base/Cellar/foo/../foo/2.0"

# Exact literals remain accepted.
exact="${work}/exact"
make_case "${exact}"
rm "${exact}/user/Cellar/foo"
mkdir "${exact}/user/Cellar/foo"
ln -s "${exact}/base/Cellar/foo/2.0" "${exact}/user/Cellar/foo/2.0"
homebrew-overlay-rack-is-exact-inherited-view \
  "${exact}/base/Cellar/foo" "${exact}/user/Cellar/foo"

python3 - "${repo}/Library/Homebrew/utils/overlay.sh" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
start = source.index("homebrew-overlay-rack-is-exact-inherited-view()")
end = source.index("\n}\n", start)
body = source[start:end]
assert "readlink -f" not in body
assert body.count('readlink -- "${local_') >= 2
assert body.count('== "${base_') >= 2
PY

printf 'overlay rack recovery exactness test: PASS\n'
