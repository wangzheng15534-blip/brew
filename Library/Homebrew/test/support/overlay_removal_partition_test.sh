#!/bin/bash
# Static control-flow guard for mixed local/inherited removal semantics.
# Full CLI/RSpec coverage remains the authoritative target-host check, but this
# offline guard prevents the exact force-uninstall/autoremove regressions found
# by the final audit from silently returning.
set -euo pipefail

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repo="$(cd "${repo}" && pwd -P)"

python3 - \
  "${repo}/Library/Homebrew/uninstall.rb" \
  "${repo}/Library/Homebrew/cleanup.rb" \
  "${repo}/Library/Homebrew/utils/autoremove.rb" <<'PY'
from pathlib import Path
import sys

uninstall = Path(sys.argv[1]).read_text(encoding="utf-8")
cleanup = Path(sys.argv[2]).read_text(encoding="utf-8")
autoremove = Path(sys.argv[3]).read_text(encoding="utf-8")

uninstall_start = uninstall.index("    def self.uninstall_kegs(")
uninstall_end = uninstall.index("\n    sig {", uninstall_start)
uninstall_method = uninstall[uninstall_start:uninstall_end]
uninstall_order = [
    "if force && Homebrew::Overlay.active?",
    "local_kegs = kegs.reject",
    "local_kegs_by_rack[rack] = local_kegs",
    "kegs_by_rack = local_kegs_by_rack",
    "handle_unsatisfied_dependents(kegs_by_rack",
    "kegs.each do |keg|",
]
positions = [uninstall_method.index(fragment) for fragment in uninstall_order]
if positions != sorted(positions) or len(set(positions)) != len(positions):
    raise SystemExit(f"mixed-rack force uninstall partition is out of order: {list(zip(uninstall_order, positions))}")
for forbidden in (
    "kegs_by_rack.values.flatten.find do |keg|\n        Homebrew::Overlay.inherited_keg?",
    "kegs_by_rack.values.flatten.any? do |keg|\n        Homebrew::Overlay.inherited_keg?",
):
    force_start = uninstall_method.index("if force && Homebrew::Overlay.active?")
    force_end = uninstall_method.index("elsif", force_start)
    if forbidden in uninstall_method[force_start:force_end]:
        raise SystemExit("force uninstall rejects a mixed rack before selecting local kegs")

cleanup_start = cleanup.index("    def self.autoremove(")
cleanup_end = cleanup.index("\n  end\nend\n\nrequire", cleanup_start)
cleanup_method = cleanup[cleanup_start:cleanup_end]
cleanup_required = [
    "local_kegs_by_full_name =",
    "local_kegs = formula.installed_kegs.reject",
    "preferred_local_kegs = local_kegs_by_full_name.transform_values",
    "kegs_by_full_name: preferred_local_kegs",
    "candidate_kegs = if Homebrew::Overlay.active?",
    "removable_formulae.flat_map { |formula| local_kegs_by_full_name.fetch(formula.full_name) }",
    "kegs_by_rack = candidate_kegs.group_by(&:rack)",
    "Uninstall.uninstall_kegs(kegs_by_rack, force: Homebrew::Overlay.active?)",
]
missing = [fragment for fragment in cleanup_required if fragment not in cleanup_method]
if missing:
    raise SystemExit(f"overlay autoremove no longer selects private kegs explicitly: {missing}")
if "formula.installed_kegs.any? do |keg|\n          Homebrew::Overlay.inherited_keg?" in cleanup_method:
    raise SystemExit("overlay autoremove again rejects a whole formula when any inherited keg exists")

autoremove_required = [
    "kegs_by_full_name: KegMap",
    "def removable_formulae(formulae, casks, kegs_by_full_name: {})",
    "def installed_keg(formula, kegs_by_full_name)",
    "kegs_by_full_name.fetch(formula.full_name) { formula.any_installed_keg }",
]
missing = [fragment for fragment in autoremove_required if fragment not in autoremove]
if missing:
    raise SystemExit(f"autoremove cannot resolve metadata through the selected local keg: {missing}")
PY

printf 'overlay removal partition test: PASS\n'
