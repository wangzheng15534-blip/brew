#!/bin/bash
# Failed non-transaction installs must not retain their mutation lock or dirty marker.
set -euo pipefail

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repo="$(cd "${repo}" && pwd -P)"
# shellcheck source=../../utils/overlay.sh
source "${repo}/Library/Homebrew/utils/overlay.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/homebrew-overlay-install-failure.XXXXXX")"
trap 'exec 20>&- 21>&- 2>/dev/null || true; rm -rf -- "${work}"' EXIT

base="${work}/base"
prefix="${work}/user"
mkdir -p \
  "${base}/Cellar/foo/1.0/bin" "${base}/opt" "${base}/var/homebrew/linked" \
  "${prefix}/Cellar" "${prefix}/bin" "${prefix}/sbin" "${prefix}/include" \
  "${prefix}/lib" "${prefix}/share" "${prefix}/Frameworks" "${prefix}/opt" \
  "${prefix}/var/homebrew/linked" "${prefix}/var/homebrew/overlay/transactions/.locks" \
  "${prefix}/var/homebrew/overlay/sync"
printf 'base\n' >"${base}/Cellar/foo/1.0/bin/foo"
ln -s '../Cellar/foo/1.0' "${base}/opt/foo"
ln -s '../../../Cellar/foo/1.0' "${base}/var/homebrew/linked/foo"
homebrew-overlay-ensure-generation "${base}"
homebrew-overlay-ensure-generation "${prefix}"

export HOMEBREW_PREFIX="${prefix}"
export HOMEBREW_OVERLAY_BASE_PREFIX="${base}"
export HOMEBREW_OVERLAY=1
export HOMEBREW_OVERLAY_ACTIVE=1
unset HOMEBREW_OVERLAY_MUTATION_OWNER HOMEBREW_OVERLAY_FINALIZE_MUTATION \
  HOMEBREW_OVERLAY_MUTATION_LOCK_FD HOMEBREW_OVERLAY_OWNER_TRANSACTION_ID \
  HOMEBREW_OVERLAY_OWNER_TRANSACTION_LOCK_FD
homebrew-overlay-sync --force

# Model the exact no-keg failure state: the Ruby owner has already locked and
# dirtied the prefix, but the formula never created a local realization.
mutation_lock="$(homebrew-overlay-mutation-lock-file "${prefix}")"
exec 20<>"${mutation_lock}"
flock -x 20
homebrew-overlay-mark-generation-dirty "${prefix}"
dirty_file="$(homebrew-overlay-generation-dirty-file "${prefix}")"
test -f "${dirty_file}"
test ! -e "${prefix}/Cellar/no-keg"

# The owning failure cleanup must reconcile the empty change, clear the marker,
# and release the descriptor when the Ruby process closes it.
HOMEBREW_OVERLAY_MUTATION_LOCK_FD=20 \
HOMEBREW_OVERLAY_FINALIZE_MUTATION=1 \
  homebrew-overlay-sync --force
test ! -e "${dirty_file}"
exec 20>&-
exec 21<>"${mutation_lock}"
flock -x -n 21
flock -u 21
exec 21>&-

# Guard the FormulaInstaller integration and ordering independently of RSpec,
# which is unavailable in the offline continuation runtime.
python3 - "${repo}/Library/Homebrew/formula_installer.rb" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
assert "@overlay_mutation_owned = T.let(false, T::Boolean)" in source
install_start = source.index("  def install\n")
install_end = source.index("  sig { void }\n  def check_conflicts", install_start)
install = source[install_start:install_end]
begin = install.index("Homebrew::Overlay.begin_mutation!")
owned = install.index("@overlay_mutation_owned = true", begin)
rescue = install.index("  rescue Exception", owned)
cleanup = install.index("finalize_failed_overlay_mutation!", rescue)
assert begin < owned < rescue < cleanup

finish_start = source.index("  def finish\n")
finish_end = source.index("  sig { returns(String) }\n  def summary", finish_start)
finish = source[finish_start:finish_end]
finish_rescue = finish.index("  rescue Exception")
assert finish.index("finalize_failed_overlay_mutation!", finish_rescue) > finish_rescue

helper_start = source.index("  def finalize_failed_overlay_mutation!\n")
helper_end = source.index("\n  end", helper_start)
helper = source[helper_start:helper_end]
assert "return unless @overlay_mutation_owned" in helper
assert "Homebrew::Overlay.mutation_active?" in helper
assert "Homebrew::Overlay.sync!(mutation: true)" in helper
assert "@overlay_mutation_owned = false" in helper
PY

printf 'overlay failed-install mutation test: PASS\n'
