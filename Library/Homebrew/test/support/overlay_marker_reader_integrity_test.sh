#!/bin/bash
# Generation and overlay marker reads must bind validation to one descriptor.
set -euo pipefail

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repo="$(cd "${repo}" && pwd -P)"
# shellcheck source=../../utils/overlay.sh
source "${repo}/Library/Homebrew/utils/overlay.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/homebrew-overlay-marker-reader.XXXXXX")"
trap 'rm -rf -- "${work}"' EXIT

# Independent syscall-level reproduction of the path replacement primitive.
python3 - "${work}" <<'PY'
import os
from pathlib import Path
import sys

root = Path(sys.argv[1])
path = root / "marker"
trusted = root / "trusted"
attacker = root / "attacker"
path.write_text("trusted\n", encoding="utf-8")
attacker.write_text("attacker\n", encoding="utf-8")
fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
try:
    path.rename(trusted)
    attacker.rename(path)
    assert os.read(fd, 64) == b"trusted\n"
    assert os.fstat(fd).st_ino != os.lstat(path).st_ino
finally:
    os.close(fd)
PY

make_prefix() {
  local prefix="$1"
  mkdir -p "${prefix}/Cellar" "${prefix}/var/homebrew/locks" \
    "${prefix}/var/homebrew/overlay/transactions/.locks" \
    "${prefix}/var/homebrew/overlay/sync"
  homebrew-overlay-ensure-generation "${prefix}"
}

# Explicit generation and dirty markers must reject aliases/hardlinks rather
# than validating one pathname and reading another object.
prefix="${work}/generation-prefix"
make_prefix "${prefix}"
generation="$(homebrew-overlay-generation-file "${prefix}")"
ln "${generation}" "${work}/generation-peer"
if homebrew-overlay-read-generation "${prefix}" >/dev/null 2>&1
then
  echo 'hard-linked generation marker unexpectedly succeeded' >&2
  exit 1
fi
rm "${work}/generation-peer"
homebrew-overlay-mark-generation-dirty "${prefix}"
dirty="$(homebrew-overlay-generation-dirty-file "${prefix}")"
ln "${dirty}" "${work}/dirty-peer"
if homebrew-overlay-read-generation-dirty "${prefix}" >/dev/null 2>&1
then
  echo 'hard-linked dirty marker unexpectedly succeeded' >&2
  exit 1
fi
rm "${work}/dirty-peer"
homebrew-overlay-clear-generation-dirty "${prefix}"

# The persistent base-prefix marker is equally authoritative.
base="${work}/base"
user="${work}/user"
fake_repo="${work}/repository"
mkdir -p "${base}/Cellar" "${fake_repo}/bin"
printf '#!/bin/sh\nexit 0\n' >"${fake_repo}/bin/brew"
chmod 0755 "${fake_repo}/bin/brew"
homebrew-overlay-ensure-generation "${base}"
homebrew-overlay-initialize-prefix "${base}" "${fake_repo}" "${user}" >/dev/null
base_marker="${user}/var/homebrew/overlay/base-prefix"
ln "${base_marker}" "${work}/base-prefix-peer"
if homebrew-overlay-initialize-prefix "${base}" "${fake_repo}" "${user}" >/dev/null 2>&1
then
  echo 'hard-linked base-prefix marker unexpectedly succeeded' >&2
  exit 1
fi
rm "${work}/base-prefix-peer"

# Local-keg drift markers and the warning suppression marker must reject hard
# links as well. Neither peer may be modified by the failed read.
base_key="$(homebrew-overlay-read-generation "${base}")"
mkdir -p "${user}/Cellar/foo/1.0"
printf '%s\n' "${base_key}" >"${user}/Cellar/foo/1.0/.brew-overlay-base-generation"
base_generation_marker="${user}/Cellar/foo/1.0/.brew-overlay-base-generation"
ln "${base_generation_marker}" "${work}/base-generation-peer"
if homebrew-overlay-update-base-drift "${user}" "${base_key}" >/dev/null 2>&1
then
  echo 'hard-linked base-generation marker unexpectedly succeeded' >&2
  exit 1
fi
grep -qx "${base_key}" "${work}/base-generation-peer"
rm "${work}/base-generation-peer"

printf '%064d\n' 0 >"${base_generation_marker}"
homebrew-overlay-update-base-drift "${user}" "${base_key}" >/dev/null 2>&1
warned="${user}/var/homebrew/overlay/base-drift.warned"
test -f "${warned}"
cp "${warned}" "${work}/warned-contents"
ln "${warned}" "${work}/warned-peer"
if homebrew-overlay-update-base-drift "${user}" "${base_key}" >/dev/null 2>&1
then
  echo 'hard-linked base-drift warning marker unexpectedly succeeded' >&2
  exit 1
fi
cmp -s "${work}/warned-peer" "${work}/warned-contents"

# Source guards ensure every authoritative reader uses the descriptor helper,
# including Ruby's diagnostic traversal of local base-generation markers.
python3 - "${repo}/Library/Homebrew/utils/overlay.sh" "${repo}/Library/Homebrew/overlay.rb" <<'PY'
from pathlib import Path
import sys

shell = Path(sys.argv[1]).read_text(encoding="utf-8")
ruby = Path(sys.argv[2]).read_text(encoding="utf-8")
assert "homebrew-overlay-read-line()" in shell
assert "homebrew-overlay-read-digest()" in shell
reader_start = shell.index("homebrew-overlay-read-line()")
reader_end = shell.index("\n}\n", reader_start) + 3
reader = shell[reader_start:reader_end]
for required in (
    'exec {file_fd}<"${file}"',
    'homebrew-overlay-lock-fd-valid',
    '"/proc/self/fd/${file_fd}"',
    'IFS= read -r -u "${file_fd}"',
):
    assert required in reader, required
assert reader.count("homebrew-overlay-lock-fd-valid") >= 2

state_digest_start = shell.index("homebrew-overlay-state-digest()")
state_digest_end = shell.index("\n}\n", state_digest_start)
assert "homebrew-overlay-read-digest" in shell[state_digest_start:state_digest_end]

for function, marker in (
    ("homebrew-overlay-read-generation-dirty()", "homebrew-overlay-read-line"),
    ("homebrew-overlay-read-generation()", "homebrew-overlay-read-line"),
    ("homebrew-overlay-initialize-prefix()", "homebrew-overlay-read-line"),
    ("homebrew-overlay-update-base-drift()", "homebrew-overlay-read-line"),
):
    start = shell.index(function)
    end = shell.index("\n}\n", start)
    assert marker in shell[start:end], function

start = ruby.index("    def self.base_generation_drift")
end = ruby.index("\n    sig { params(transaction:", start)
body = ruby[start:end]
assert "read_owned_file" in body
assert "marker.read" not in body
PY

printf 'overlay marker reader integrity test: PASS\n'
