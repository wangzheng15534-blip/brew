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

formula_paths=()
ignored_paths=()
for ((i = 1; i <= formulae; i++))
do
  formula_paths+=("${base}/Cellar/tool-${i}/1.0")
done
for ((i = 1; i <= ignored_entries; i++))
do
  ignored_paths+=("${base}/share/large/group-$((i / 100))/entry-${i}")
done
((${#formula_paths[@]} == 0)) || mkdir -p -- "${formula_paths[@]}"
((${#ignored_paths[@]} == 0)) || mkdir -p -- "${ignored_paths[@]}"

# A patched administrator invocation creates and subsequently bumps this
# explicit generation after successful package mutations. This makes the
# unchanged developer path independent of the number of installed formulae.
homebrew-overlay-ensure-generation "${base}"

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

# Prove that the unchanged fast path no longer performs a structural `find`.
# The test shell and flock still run, but package count is no longer on the hot
# path. A generation change explicitly re-enables reconciliation.
mkdir "${work}/no-find"
cat >"${work}/no-find/find" <<'EOF_FIND'
#!/bin/sh
echo "unexpected find on unchanged overlay generation" >&2
exit 97
EOF_FIND
chmod 0755 "${work}/no-find/find"
PATH="${work}/no-find:${PATH}" bash "${repo}/Library/Homebrew/utils/overlay.sh" --quick-sync

mkdir -p "${base}/Cellar/new-tool/1.0"
homebrew-overlay-bump-generation "${base}" >/dev/null
bash "${repo}/Library/Homebrew/utils/overlay.sh" --quick-sync
test -L "${user}/Cellar/new-tool"

# Generous enough for slow virtualized CI while still catching the old full
# structural scans. The no-find assertion above is the primary regression guard.
test "$((second_ns / 1000000))" -lt 1000
