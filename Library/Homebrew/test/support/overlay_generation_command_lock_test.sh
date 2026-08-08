#!/bin/bash
# Direct generation commands must serialize with the package mutation lock.
set -euo pipefail

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repo="$(cd "${repo}" && pwd -P)"
script="${repo}/Library/Homebrew/utils/overlay.sh"
# shellcheck source=../../utils/overlay.sh
source "${script}"

work="$(mktemp -d "${TMPDIR:-/tmp}/homebrew-overlay-generation-command.XXXXXX")"
trap 'exec 20>&- 21>&- 2>/dev/null || true; rm -rf -- "${work}"' EXIT
prefix="${work}/prefix"
mkdir -p "${prefix}/Cellar" "${prefix}/var/homebrew/locks"
homebrew-overlay-ensure-generation "${prefix}"
mutation_lock="$(homebrew-overlay-mutation-lock-file "${prefix}")"

exec 20<>"${mutation_lock}"
flock -x 20
homebrew-overlay-mark-generation-dirty "${prefix}"
dirty="$(homebrew-overlay-generation-dirty-file "${prefix}")"
test -f "${dirty}"

# A separate command may not bless, recover, or even initialize a generation
# while the package view belongs to another live open-file description.
for command in --ensure-generation --mark-generation-dirty --recover-generation --bump-generation
do
  if env -u HOMEBREW_OVERLAY_MUTATION_LOCK_FD \
    bash "${script}" "${command}" "${prefix}" >"${work}/${command#--}.out" 2>"${work}/${command#--}.err"
  then
    echo "${command} crossed a live package mutation" >&2
    exit 1
  fi
  grep -q 'another Homebrew package mutation is still active' "${work}/${command#--}.err"
done
test -f "${dirty}"

# Reopening the same inode is not ownership; only the inherited locking open
# file description may authorize the nested Ruby-to-shell command.
exec 21<>"${mutation_lock}"
if HOMEBREW_OVERLAY_MUTATION_LOCK_FD=21 \
  bash "${script}" --bump-generation "${prefix}" >"${work}/reopened.out" 2>"${work}/reopened.err"
then
  echo 'reopened mutation descriptor unexpectedly authorized generation bump' >&2
  exit 1
fi
grep -q 'unsafe inherited Homebrew overlay mutation lock descriptor' "${work}/reopened.err"
exec 21>&-
test -f "${dirty}"

HOMEBREW_OVERLAY_MUTATION_LOCK_FD=20 \
  bash "${script}" --bump-generation "${prefix}" >"${work}/owned.out"
homebrew-overlay-base-generation-valid "$(cat "${work}/owned.out")"
test ! -e "${dirty}"

# Once the owner closes, an ordinary direct command can acquire the lock itself.
exec 20>&-
bash "${script}" --mark-generation-dirty "${prefix}"
test -f "${dirty}"
bash "${script}" --recover-generation "${prefix}" >/dev/null
test ! -e "${dirty}"

python3 - "${script}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
assert "homebrew-overlay-run-generation-command()" in source
case = source[source.index('case "${1:-}" in'):]
for command in (
    "--ensure-generation)",
    "--mark-generation-dirty)",
    "--recover-generation)",
    "--bump-generation)",
):
    start = case.index(command)
    end = case.index(";;", start)
    assert "homebrew-overlay-run-generation-command" in case[start:end], command
PY

printf 'overlay generation command lock test: PASS\n'
