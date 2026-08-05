#!/bin/bash
# Illustrative no-network synchronization benchmark. This is not a universal
# performance threshold; compare first and unchanged second synchronization.
set -euo pipefail

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
links="${LINK_COUNT:-500}"
directories="${DIRECTORY_COUNT:-1000}"
source "${repo}/Library/Homebrew/utils/overlay.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/homebrew-native-overlay-perf.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
base="${work}/base"
user="${work}/user"

mkdir -p \
  "${base}/Cellar/tools/1.0/bin" \
  "${base}/bin" \
  "${base}/var/state" \
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

for ((i = 1; i <= links; i++))
do
  printf '#!/bin/sh\n' >"${base}/Cellar/tools/1.0/bin/tool-${i}"
  chmod 0755 "${base}/Cellar/tools/1.0/bin/tool-${i}"
  ln -s "../Cellar/tools/1.0/bin/tool-${i}" "${base}/bin/tool-${i}"
done
for ((i = 1; i <= directories; i++))
do
  mkdir -p "${base}/var/state/group-$((i / 100))/entry-${i}"
done

export HOMEBREW_PREFIX="${user}"
export HOMEBREW_OVERLAY_BASE_PREFIX="${base}"

printf 'links=%s directories=%s\n' "${links}" "${directories}"
/usr/bin/time -f 'first_elapsed=%e first_user=%U first_sys=%S maxrss_kb=%M' \
  /bin/bash "${repo}/Library/Homebrew/utils/overlay.sh" --sync
/usr/bin/time -f 'second_elapsed=%e second_user=%U second_sys=%S maxrss_kb=%M' \
  /bin/bash "${repo}/Library/Homebrew/utils/overlay.sh" --sync
