#!/bin/bash
# Regression gate for every implementation finding in the final native-overlay
# audit. This file began as a defect reproducer; success now means the corrected
# behavior was observed and the audited source guards remain present.
set -euo pipefail

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repo="$(cd "${repo}" && pwd -P)"

run() {
  local test_name="$1"
  printf '=== %s ===\n' "${test_name}"
  bash "${repo}/Library/Homebrew/test/support/${test_name}" "${repo}"
}

# F1: live transaction ownership and abandoned-journal recovery.
run overlay_transaction_recovery_test.sh

# F2/F3: convergent version unions, exact target validation, managed removal.
run overlay_view_reconciliation_test.sh

# F4/F6: force uninstall and autoremove select private kegs from mixed racks.
run overlay_removal_partition_test.sh

# F5: the durable keg boundary precedes non-reversible native side effects.
run overlay_commit_boundary_test.sh

# F7: pre-mutation dirty markers, active-owner exclusion, crash recovery.
run overlay_generation_recovery_test.sh

printf 'final native overlay audit regression gate: PASS\n'
