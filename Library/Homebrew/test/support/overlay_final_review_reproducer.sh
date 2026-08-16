#!/bin/bash
# Aggregate regression gate for the complete native-overlay review. Every
# standalone overlay support test must be listed here before this gate can pass.
set -euo pipefail
umask 077

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repo="$(cd "${repo}" && pwd -P)"
support="${repo}/Library/Homebrew/test/support"

tests=(
  overlay_test.sh
  overlay_review_findings.sh
  overlay_lock_safety_test.sh
  overlay_lock_ownership_test.sh
  overlay_generation_recovery_test.sh
  overlay_generation_command_lock_test.sh
  overlay_install_failure_test.sh
  overlay_transaction_recovery_test.sh
  overlay_transaction_integrity_test.sh
  overlay_transaction_publication_durability_test.sh
  overlay_sync_integrity_test.sh
  overlay_cellar_integrity_test.sh
  overlay_rack_recovery_exactness_test.sh
  overlay_view_reconciliation_test.sh
  overlay_ruby_reader_integrity_test.sh
  overlay_runtime_boot_test.sh
  overlay_marker_reader_integrity_test.sh
  overlay_removal_partition_test.sh
  overlay_commit_boundary_test.sh
)

for candidate in "${support}"/overlay_*test.sh
do
  candidate="${candidate##*/}"
  listed=0
  for test_name in "${tests[@]}"
  do
    if [[ "${candidate}" == "${test_name}" ]]
    then
      listed=1
      break
    fi
  done
  if [[ "${listed}" -ne 1 ]]
  then
    echo "Error: overlay regression suite is missing from the aggregate gate: ${candidate}" >&2
    exit 1
  fi
done

for test_name in "${tests[@]}"
do
  test_path="${support}/${test_name}"
  [[ -f "${test_path}" && -x "${test_path}" ]] || {
    echo "Error: unavailable overlay regression suite: ${test_name}" >&2
    exit 1
  }
  printf '=== %s ===\n' "${test_name}"
  bash "${test_path}" "${repo}"
done

printf 'complete native overlay audit regression gate: PASS\n'
