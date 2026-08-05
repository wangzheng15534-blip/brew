#!/bin/bash
# Offline synchronization benchmark and regression guard. The lower prefix's
# recursive link tree is intentionally irrelevant; only the native package view
# (Cellar/opt/linked) is indexed.
set -euo pipefail

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repo="$(cd "${repo}" && pwd -P)"
formulae="${FORMULA_COUNT:-500}"
ignored_entries="${IGNORED_ENTRY_COUNT:-1000}"
source "${repo}/Library/Homebrew/utils/overlay.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/homebrew-native-overlay-perf.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
base="${work}/base"
user="${work}/user"

mkdir -p \
  "${base}/Cellar" "${base}/bin" "${base}/share/large" \
  "${base}/opt" "${base}/var/homebrew/linked" \
  "${user}/Cellar" "${user}/bin" "${user}/etc" "${user}/Frameworks" \
  "${user}/include" "${user}/lib" "${user}/opt" "${user}/sbin" \
  "${user}/share" "${user}/var/homebrew/linked" "${user}/var/homebrew/locks" \
  "${user}/var/homebrew/overlay/transactions" "${user}/var/homebrew/overlay/sync"

for ((i = 1; i <= formulae; i++))
do
  mkdir -p "${base}/Cellar/tool-${i}/1.0/bin"
  printf '#!/bin/sh\n' >"${base}/Cellar/tool-${i}/1.0/bin/tool-${i}"
  ln -s "../Cellar/tool-${i}/1.0" "${base}/opt/tool-${i}"
done
for ((i = 1; i <= ignored_entries; i++))
do
  mkdir -p "${base}/share/large/group-$((i / 100))/entry-${i}"
done

export HOMEBREW_PREFIX="${user}"
export HOMEBREW_OVERLAY_BASE_PREFIX="${base}"

printf 'formulae=%s ignored_recursive_entries=%s\n' "${formulae}" "${ignored_entries}"
start_ns="$(date +%s%N)"
bash "${repo}/Library/Homebrew/utils/overlay.sh" --sync
first_ns=$(( $(date +%s%N) - start_ns ))
start_ns="$(date +%s%N)"
bash "${repo}/Library/Homebrew/utils/overlay.sh" --quick-sync
second_ns=$(( $(date +%s%N) - start_ns ))
printf 'first_ms=%s second_unchanged_ms=%s\n' "$((first_ns / 1000000))" "$((second_ns / 1000000))"

test "$(find "${user}/Cellar" -mindepth 1 -maxdepth 1 -type l | wc -l)" -eq "${formulae}"
test ! -e "${user}/share/large"
# This is deliberately generous for slow CI hosts. It guards against the prior
# recursive, multi-second-per-root no-change implementation rather than acting
# as a universal performance promise.
test "$((second_ns / 1000000))" -lt 5000
