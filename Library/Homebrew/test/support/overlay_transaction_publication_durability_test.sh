#!/bin/bash
# File-and-directory durability ordering for formula transaction publication and recovery.
set -euo pipefail

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repo="$(cd "${repo}" && pwd -P)"
# shellcheck source=../../utils/overlay.sh
source "${repo}/Library/Homebrew/utils/overlay.sh"

python3 - "${repo}/Library/Homebrew/overlay.rb" "${repo}/Library/Homebrew/utils/overlay.sh" <<'PY'
from pathlib import Path
import sys

ruby = Path(sys.argv[1]).read_text(encoding="utf-8")
shell = Path(sys.argv[2]).read_text(encoding="utf-8")

def body(source: str, start_fragment: str, end_fragment: str) -> str:
    start = source.index(start_fragment)
    end = source.index(end_fragment, start)
    return source[start:end]

def ordered(section: str, fragments: list[str], description: str) -> None:
    positions = [section.index(fragment) for fragment in fragments]
    if positions != sorted(positions) or len(set(positions)) != len(positions):
        raise SystemExit(f"{description} is out of order: {list(zip(fragments, positions))}")

prepare = body(ruby, "      def prepare_replacement_rack!\n", "\n      # Formulae built from source",)
ordered(prepare, [
    "File.rename(staging_version, replacement_rack/version)",
    "Overlay.durable_atomic_write!(marker, \"#{id}\\n\", mode: 0600)",
    "Overlay.fsync_directory!(staging_rack)",
    "Overlay.fsync_directory!(replacement_rack)",
    "Overlay.fsync_directory!(@replacement_root)",
    "Overlay.fsync_directory!(@replacement_root.parent)",
    "Overlay.fsync_directory!(@replacement_root.parent.parent)",
], "replacement-rack durability")

commit = body(ruby, "      def commit!\n", "\n      sig { void }\n      def rollback!",)
ordered(commit, [
    "Overlay.fsync_tree!(final_version)",
    "Overlay.record_base_generation!(final_version, base_generation)",
    "write_state(\"committing\")",
    "Overlay.durable_unlink!(marker)",
    "write_state(\"committed\")",
], "commit-marker durability")

exchange = body(ruby, "    def self.atomic_exchange!(left, right)\n", "\n    # Remove a newly created",)
ordered(exchange, [
    "mv = %w[/bin/mv /usr/bin/mv].find",
    "Homebrew.safe_system mv, \"--exchange\", \"--no-target-directory\"",
    "[left.parent, right.parent].uniq.each { |parent| fsync_directory!(parent) }",
], "rack-exchange durability")

tree = body(
    ruby,
    "    def self.fsync_tree!(root)\n",
    "\n    sig { params(path: Pathname, contents: String, mode: Integer).void }",
)
for required in (
    "File::NOFOLLOW",
    "file.fsync",
    "directories.reverse_each",
    "expected_device: device",
    "expected_inode: inode",
):
    if required not in tree:
        raise SystemExit(f"missing durable keg payload guard: {required}")

record = body(
    ruby,
    "    def self.record_base_generation!(keg_path, generation)\n",
    "\n    sig { returns(T::Array[Pathname]) }",
)
if "durable_atomic_write!(marker, \"#{generation}\\n\", mode: 0600)" not in record:
    raise SystemExit("base-generation marker is not durably published")

cleanup = body(
    ruby,
    "      def cleanup_paths!\n",
    "\n      sig { params(path: Pathname).void }\n      def remove_tree_durable!",
)
required_cleanup = [
    "remove_tree_durable!(@staging_root)",
    "remove_tree_durable!(@replacement_root)",
    "remove_tree_durable!(@pending_transaction_dir)",
    "remove_tree_durable!(transaction_dir)",
    "Overlay.fsync_directory!(@owner_lock_path.parent)",
]
for fragment in required_cleanup:
    if fragment not in cleanup:
        raise SystemExit(f"missing durable transaction cleanup: {fragment}")

recovery = body(shell, "homebrew-overlay-recover-formula-transactions() {\n", "\nhomebrew-overlay-sync-unlocked() {",)
for forbidden in ("mv -T --", 'rm -f -- "${final_marker}"'):
    if forbidden in recovery:
        raise SystemExit(f"non-durable recovery operation remains: {forbidden}")
for required in (
    "homebrew-overlay-move-durable",
    "homebrew-overlay-remove-tree-durable",
    'homebrew-overlay-remove-durable "${final_marker}"',
    'homebrew-overlay-fsync-directory "${local_rack%/*}"',
):
    if required not in recovery:
        raise SystemExit(f"missing durable recovery operation: {required}")
PY

work="$(mktemp -d "${TMPDIR:-/tmp}/homebrew-overlay-publication-durability.XXXXXX")"
trap 'rm -rf -- "${work}"' EXIT
prefix="${work}/prefix"
mkdir -p "${prefix}/Cellar" "${prefix}/var/homebrew/locks" \
  "${work}/source-parent/item/subdir" "${work}/destination-parent" \
  "${work}/remove-parent/tree/subdir"
printf 'payload\n' >"${work}/source-parent/item/subdir/file"
printf 'remove\n' >"${work}/remove-parent/tree/subdir/file"

export HOMEBREW_PREFIX="${prefix}"
lock_file="$(homebrew-overlay-prepare-mutation-lock "${prefix}")"
exec {mutation_fd}<>"${lock_file}"
flock -x "${mutation_fd}"

sync_log="${work}/sync.log"
sync() {
  printf '%s\0' "$@" >>"${sync_log}"
  command sync "$@"
}

homebrew-overlay-move-durable \
  "${work}/source-parent/item" "${work}/destination-parent/item"
test ! -e "${work}/source-parent/item"
test -f "${work}/destination-parent/item/subdir/file"
homebrew-overlay-remove-tree-durable "${work}/remove-parent/tree"
test ! -e "${work}/remove-parent/tree"

python3 - "${sync_log}" "${work}" <<'PY'
from pathlib import Path
import sys

raw = Path(sys.argv[1]).read_bytes().split(b"\0")
args = [item.decode() for item in raw if item]
root = sys.argv[2]
expected = [
    "-d", "--", f"{root}/source-parent",
    "-d", "--", f"{root}/destination-parent",
    "-d", "--", f"{root}/remove-parent",
]
pos = 0
for value in expected:
    try:
        pos = args.index(value, pos) + 1
    except ValueError as e:
        raise SystemExit(f"missing ordered directory fsync argument {value!r}: {args}") from e
PY

flock -u "${mutation_fd}"
exec {mutation_fd}>&-
printf 'overlay transaction publication durability test: PASS\n'
