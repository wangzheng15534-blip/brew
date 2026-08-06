#!/bin/bash
set -euo pipefail

repository="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repository="$(cd "${repository}" && pwd -P)"

python3 - "${repository}/Library/Homebrew/formula_installer.rb" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
start = source.index("  def finish\n")
end = source.index("\n  sig { returns(String) }\n  def summary", start)
finish = source[start:end]

ordered = [
    "@overlay_transaction&.publish!",
    "fix_dynamic_linkage(keg) if fix_linkage",
    "@overlay_transaction.commit!",
    "link(keg)",
    "install_service",
    "formula.install_etc_var",
]
positions = [finish.index(fragment) for fragment in ordered]
if positions != sorted(positions) or len(set(positions)) != len(positions):
    raise SystemExit(f"overlay package commit boundary is out of order: {list(zip(ordered, positions))}")

required = [
    "return if overlay_package_committed?",
    "transaction.rollback! if transaction && !transaction.finished?",
    "matching native Homebrew's installed-but-unlinked/post-install-failed",
]
for fragment in required:
    if fragment not in source:
        raise SystemExit(f"missing overlay commit-boundary guard: {fragment}")
PY

printf 'overlay commit boundary test: PASS\n'
