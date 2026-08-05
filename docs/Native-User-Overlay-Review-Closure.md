# Native overlay review closure

This document closes the findings recorded in
[the rigorous review](Native-User-Overlay-Review.md). That review remains an
unaltered historical record of the implementation at `18e50f0`. The corrected
implementation assessed here is the native two-prefix design through
`6ceedb6`:

```text
administrator prefix: /home/linuxbrew/.linuxbrew
user prefix:          $HOME/.linuxbrew
```

`XDG_DATA_HOME` does not redirect the user package prefix. The implementation
has no daemon, named environments, claims database, or separate `pkgs` tree.

## Closure standard

A finding is marked **closed** when its reviewed failure mode is prevented or
recovered and a focused committed test covers the correction. **Closed by
design change** means the unsafe mechanism was removed rather than repaired.
**Mitigated boundary** means the strongest form is impossible in a non-service,
mutable-lower-prefix design, but the minimum safety requirement from the review
is implemented and the remaining limitation is explicit.

The available offline checks are not a substitute for Homebrew's complete Ruby
4 test matrix. Release acceptance on a target host still requires the blocked
checks listed below.

## R1–R12 disposition

### R1 — launcher and synchronizer suppressed failures: closed

Commit `4f177f1` makes bootstrap, directory validation, desired-view creation,
link application, state publication, and synchronization propagate failure
explicitly under the launcher's `set -u` execution model. The synchronizer
validates the complete desired transition before removing managed links and
uses a durable sync journal for recovery.

Evidence:

- `Library/Homebrew/utils/overlay.sh`
- `bin/brew`
- `overlay_review_findings.sh` cases 1 and 5
- `overlay_test.sh` bootstrap and unsafe-parent regressions

### R2 — inherited-rack replacement was not atomic or recoverable: closed

Commit `6fcf050` introduces `Homebrew::Overlay::FormulaTransaction`. An
inherited replacement is built in a private staging rack while the lower rack
remains visible. A complete replacement rack is prepared and published with
Linux `renameat2(RENAME_EXCHANGE)` under the formula lock. Every durable phase
is journaled. Startup recovery either restores the previous rack or accepts a
fully committed rack, and failures represented by exceptions or
`Homebrew.failed?` roll back the transaction.

Commit `e13ea02` adds generation validation before publication and commit,
rejects writes through inherited version symlinks, and validates committed
metadata during recovery.

Evidence:

- `Library/Homebrew/overlay.rb`
- `Library/Homebrew/formula_installer.rb`
- `Library/Homebrew/install.rb`
- `Library/Homebrew/reinstall/reinstall.rb`
- `overlay_transaction_recovery_test.sh`, covering every durable journal state
- installer and overlay unit specifications

### R3 — migration could delete local files through an inherited target: closed

Commit `c826826` makes migration detect an administrator-provided destination
before the migrator moves, merges, or deletes any local file. A strict explicit
migration fails; automatic migration warns and leaves the old local rack
untouched.

Evidence:

- `Library/Homebrew/migrator.rb`
- `Library/Homebrew/cmd/migrate.rb`
- `Library/Homebrew/test/migrator_spec.rb`

### R4 — projected directory links were not a correct union: closed by design change

Commit `4f177f1` removes recursive projection of the administrator `bin`,
`sbin`, `include`, `lib`, `share`, `Frameworks`, `etc`, and general `var` link
trees. The overlay now synchronizes only the package view Homebrew needs:
Cellar racks and versions, `opt`, and linked-keg records. `brew shellenv` places
the user `bin`/`sbin` before the administrator `bin`/`sbin` for executable
fallback. Because the unsafe projected directory union no longer exists, a
local formula cannot erase lower entries from that projection.

This correction intentionally does not claim that the two general-purpose
prefix trees form one filesystem union.

Evidence:

- `Library/Homebrew/utils/overlay.sh`
- `Library/Homebrew/cmd/shellenv.sh`
- `overlay_review_findings.sh` case 4
- `overlay_test.sh` package-view and shell fallback assertions

### R5 — `brew doctor` recommended deleting the administrator Cellar: closed

Commit `c826826` suppresses the incompatible multiple-Cellar and non-default
prefix advice while an overlay is active and adds overlay-specific checks for
the lower Cellar, user-prefix ownership, managed state, transaction state, and
generation drift. No overlay diagnostic proposes removing the administrator
Cellar.

Evidence:

- `Library/Homebrew/diagnostic.rb`
- `Library/Homebrew/test/diagnostic_checks_spec.rb`

### R6 — every invocation recursively rebuilt the prefix: closed

Commit `4f177f1` first limits synchronization to the native package view.
Commit `2d359bd` then adds one validated 64-hex mutation generation to each
native prefix. An unchanged invocation compares the administrator and user
generations with the committed view stamp and returns before Cellar traversal
or drift scanning. A structural scan is retained only to initialize an older
administrator prefix that has no generation marker.

Evidence:

- `Library/Homebrew/utils/overlay.sh`
- mutation-generation calls in `formula_installer.rb`, `keg.rb`, and
  `cmd/postinstall.rb`
- `overlay_performance_smoke.sh`, including a fake-`find` assertion that the
  unchanged path does not traverse package trees
- latest 500-formula smoke result recorded in the final verification log

### R7 — native command semantics were only partially integrated: closed for the reviewed command set

Commit `c826826` handles every command path enumerated in R7 before side
effects:

- inherited `brew link` and `brew postinstall` are rejected;
- `brew unlink` is rejected when administrator fallback would make unlinking
  misleading;
- Bundle cleanup excludes inherited-only formulae and reports removal only when
  the child command succeeds;
- dependent checks model the administrator formula that reappears after local
  removal;
- transaction rollback covers nested and non-raising installation failures;
- migration is rejected before touching local files.

The implementation does not claim compatibility with every future or external
Homebrew command. Any unclassified command that mutates an inherited keg must
fail the inherited-path checks rather than write through the lower layer.

Evidence:

- `Library/Homebrew/cmd/link.rb`
- `Library/Homebrew/cmd/unlink.rb`
- `Library/Homebrew/cmd/postinstall.rb`
- `Library/Homebrew/bundle/subcommand/cleanup.rb`
- `Library/Homebrew/installed_dependents.rb`
- command-focused unit specifications

### R8 — lower state and local dependency graphs were version-inconsistent: mitigated boundary

Commits `e13ea02` and `2d359bd` implement the minimum correction required by
the review:

- capture the administrator generation before a private build;
- verify it during staging, immediately before publication, and during commit;
- abort and roll back when it changes during an install;
- record the exact generation in every private keg;
- detect later drift at startup and in `brew doctor`;
- require an explicit generation bump after any manual lower-prefix edit.

A no-service design cannot make a mutable administrator prefix an immutable
snapshot or prevent an administrator from changing it between user commands.
It also intentionally reuses lower binaries with their original absolute base
paths. Those are documented operational boundaries, not silently presented as
an isolated environment. Administrators must not mutate the base while user
installs are running, and stale private formulae must be reinstalled after a
reported generation change.

Evidence:

- generation and drift logic in `overlay.rb` and `utils/overlay.sh`
- `formula_installer_spec.rb`, `overlay_spec.rb`, and diagnostic specifications
- generation-race and drift cases in the committed shell fixtures

### R9 — initialization overwrote `brew.env`: closed

Commit `4f177f1` moves generated settings to
`$HOME/.linuxbrew/etc/homebrew/overlay.env`. The launcher reads it separately;
initialization never rewrites the developer-owned `brew.env`.

Evidence: `overlay_review_findings.sh` case 3 and `overlay_test.sh`.

### R10 — lexical state paths could escape the prefix: closed

Commit `4f177f1` replaces absolute TSV paths with a NUL-delimited map of
validated relative paths and exact absolute targets. Empty components, `.`,
`..`, absolute relative-fields, newlines, unsafe parents, and symlinked managed
parents are rejected. Removal occurs only when the destination remains under
the owned user prefix and still matches the recorded target.

Evidence: `overlay_review_findings.sh` case 6 and the corrupt-state case in
`overlay_test.sh`.

### R11 — base oldname symlinks appeared as installed racks: closed

Commit `4f177f1` admits only real administrator Cellar rack directories and real
version directories when constructing the inherited package view. Cellar
oldname and alias symlinks are ignored.

Evidence: `overlay_review_findings.sh` case 7 and `overlay_test.sh`.

### R12 — surfaced delivery was not self-contained: closed by the final handoff gate

The final handoff has one checksum root. Its delivery archive contains the
verified Git bundle, source archive, net patch, atomic format-patch series,
review closure, verification log, handoff files, and `SHA256SUMS`. Verification
extracts that archive into a new directory and runs `sha256sum -c SHA256SUMS`
there. Individually linked convenience files are not advertised as a second
checksum-complete directory.

## Current committed regression matrix

The following offline checks are committed or reproducible from the final
handoff:

- policy composer self-test;
- Bash syntax for every changed shell file;
- Ruby syntax for every changed Ruby file and specification;
- native package-view and `$HOME/.linuxbrew` shell integration;
- all seven original adversarial shell findings;
- durable formula-transaction crash recovery;
- explicit-generation unchanged-path performance smoke;
- focused command, migration, Bundle, dependent, diagnostic, installer, and
  overlay specifications;
- Git whitespace, object, bundle, independent-clone, patch-replay, and source
  archive checks.

## Checks still requiring the target build environment

These are verification blockers, not unreported code fixes:

- Homebrew's complete RSpec, RuboCop, and Sorbet suites under its requested Ruby
  4.0.6 and development gem set;
- real bottle and source installations across representative formula classes;
- process-kill injection from a real Ruby installer at every transaction phase;
- concurrent administrator mutation tests on the deployment filesystem;
- arbitrary casks, which are outside administrator-package inheritance.

No dependency was downloaded or substituted to bypass the offline environment.
Until the target-host matrix passes, this fork should be deployed only on
controlled development hosts with backups of both native prefixes.
