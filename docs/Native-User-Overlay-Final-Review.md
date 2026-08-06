# Final native overlay review

> **Historical review.** This document assesses implementation commit
> `3ec474c` and preserves the release-blocking findings that drove the
> corrections. See the current
> [Final native-overlay review closure](Native-User-Overlay-Final-Review-Closure.md).

Review target:

```text
branch: overlay-store
implementation HEAD: 3ec474c5bf3d0942e523102be263405c84e50f21
implementation tree: 7021b23f2fbc85cea1952c9006f266010cc9df0b
administrator prefix: /home/linuxbrew/.linuxbrew
user prefix: $HOME/.linuxbrew
```

## Verdict

**Reject this implementation for production deployment.**

The final tree improves the original prototype substantially, and its Git/source
handoff is recoverable from the complete delivery archive. However, the package
manager itself still has two release-blocking state-machine defects and several
high-severity command/rollback gaps. In particular, a concurrent read-only
`brew` process can delete another live process's installation transaction, and
the native version-union synchronizer is not convergent.

The prior review-closure document's statement that all actionable R1–R12 issues
are closed is therefore not supported by the final implementation. R2 and R7
must be reopened, and the version-union defects are new release blockers.

## Severity-ranked findings

### F1 — Critical: startup recovery deletes live installation transactions

`FormulaTransaction#start!` creates a durable journal in state `staging` and a
staging rack, but it does not hold the overlay synchronization lock or a
transaction-owner lock for the transaction lifetime. Every overlay invocation
runs `homebrew-overlay-recover-formula-transactions` before the generation fast
path. Recovery treats every journal as abandoned and does not test whether its
owner is alive or whether it can acquire an owner lock.

Relevant code:

```text
Library/Homebrew/overlay.rb:127-147
Library/Homebrew/utils/overlay.sh:765-925
Library/Homebrew/utils/overlay.sh:951-980
```

The committed audit reproducer starts a live process, creates the same valid
`<pid>-<nonce>` journal shape used by `FormulaTransaction`, then performs a
second synchronization. The owner remains alive while its journal and staging
tree are deleted:

```text
CONFIRMED: live transaction owner remains running while recovery deletes its journal and staging tree
```

This is not limited to two writers of the same formula. A read-only command or
an installation of another formula is sufficient because startup recovery does
not acquire the formula lock. In `published` state, a second invocation can
also roll back the active rack while the first process is linking or running
post-install work.

**Required correction:** hold a transaction-specific advisory lock from
`start!` through commit/rollback. Recovery must attempt that lock
non-blockingly and recover only when it can prove no live owner holds it. A PID
check alone is insufficient because of PID reuse.

### F2 — Critical: version-union synchronization is not a fixed point

For a real user rack, `homebrew-overlay-build-view` records a lower version only
when the destination child is missing:

```bash
[[ -e "${user_rack}/${version_name}" || -L "${user_rack}/${version_name}" ]] ||
  homebrew-overlay-record-pair ...
```

When synchronization creates the missing symlink, it records that symlink in
`view.state`. On the next reconciliation, the correct existing symlink is
omitted from the desired view, so `homebrew-overlay-apply-view` treats the old
managed entry as stale and removes it. A third reconciliation creates it again.

Relevant code:

```text
Library/Homebrew/utils/overlay.sh:367-432
Library/Homebrew/utils/overlay.sh:452-555
```

Executed result:

```text
CONFIRMED: repeated union-rack reconciliation alternately removes and recreates the inherited version
```

This affects normal operation whenever a new administrator version is first
added to an existing local rack: the first generation change adds it, a later
package generation removes it, and a later generation re-adds it. Formula
visibility and dependency resolution therefore depend on synchronization
parity.

**Required correction:** the desired view must contain every expected inherited
child on every reconciliation. An exact existing symlink should remain in the
desired map; a missing child should be created; a real local child should shadow
the lower child; and every other existing object should be a hard conflict.

### F3 — High: inherited version children are not target-validated or reliably managed

The same existence-only condition accepts any symlink or filesystem object at a
base version name. Synchronization neither verifies that a symlink points to the
exact administrator version nor records it in managed state.

Executed result:

```text
CONFIRMED: synchronization preserves an incorrect version child and omits it from managed state
```

`FormulaTransaction#prepare_replacement_rack!` also creates inherited child
symlinks directly before synchronization. Because those paths already exist,
they are omitted from `view.state`. If the administrator later removes such a
version, reconciliation leaves a broken Cellar child:

```text
CONFIRMED: base removal leaves a transaction-created inherited child broken and unmanaged
```

A broken child is omitted by installed-package enumeration but still occupies
the target path and can block a later installation of that version.

**Required correction:** use one target-validating reconciliation rule for both
transaction-created and synchronizer-created children. The exact expected
symlink must always be represented in the committed desired state.

### F4 — High: `brew uninstall --force` rejects mixed local/inherited racks

The force path resolves every child of the rack:

```text
cmd/uninstall.rb:45-46 selects method :kegs
cli/named_args.rb:519-534 returns rack.subdirs as Keg objects
```

The overlay guard then rejects the complete batch if any resolved keg is
inherited:

```text
uninstall.rb:23-32
```

A native union rack intentionally contains local kegs and inherited kegs, so
`brew uninstall --force foo` cannot remove all private versions of `foo` while
preserving the base versions. `brew bundle cleanup --force` invokes the same
force path and is affected as well.

This finding is statically established from the exact command dispatch and
resolver path. Full CLI execution was blocked because the source requires Ruby
4.0.6 and the offline runtime does not contain Homebrew's requested Ruby/gem
set.

**Required correction:** force uninstall must partition kegs into local and
inherited sets. Remove only local kegs; reject only when no local keg was
requested or when the operation would otherwise require mutating the base.

### F5 — High: rollback is atomic only for the Cellar rack, not for installation side effects

After rack publication, `FormulaInstaller#finish` performs native linking,
service-file generation, dynamic-linkage repair, global post-install work,
`install_etc_var`, and arbitrary formula post-install logic before the
transaction commits. On failure, `FormulaTransaction#rollback!` calls
`Overlay.remove_links_to!` and exchanges the rack back.

Both the Ruby and shell cleanup helpers remove only symlinks:

```text
Library/Homebrew/overlay.rb:671-689
Library/Homebrew/utils/overlay.sh:721-747
```

Native `Keg#link` has regular-file side effects, including updates to the
`share/info/dir` index. `install_etc_var` and formula post-install code can also
write outside the keg. The rollback path neither invokes the complete native
unlink cleanup nor journals/reverts these regular paths.

Executed result:

```text
CONFIRMED: transaction rollback helper removes links but leaves regular link-tree metadata
```

The rack exchange is atomic, but the overall formula installation is not. The
documentation must not describe the complete operation as atomic until external
side effects are handled.

**Required correction:** either journal and reverse every touched external path,
or narrow the guarantee explicitly to rack publication and redesign finish
semantics. At minimum, rollback should use native keg unlink cleanup for
installed link metadata and have defined handling for `etc`, `var`, service,
and post-install effects.

### F6 — Medium: autoremove excludes valid local candidates when any base version exists

`Cleanup.autoremove` rejects a formula when any installed keg is inherited:

```ruby
formula.installed_kegs.any? { |keg| Homebrew::Overlay.inherited_keg?(keg.to_path) }
```

A version-union rack normally has both local and inherited kegs, so a local
package installed only as an unneeded dependency is permanently protected from
autoremove merely because the administrator provides another version.

Relevant code:

```text
Library/Homebrew/cleanup.rb:935-938
```

**Required correction:** calculate removal candidates from local kegs and model
the inherited fallback in the dependency graph; do not reject the formula as a
whole.

### F7 — Medium: explicit generations are not transactionally coupled to every mutation

The fast path trusts explicit generation files and performs no structural scan
when they match the saved stamp. Generation bumps occur after native Cellar or
link-tree mutations in several paths. A process killed after a mutation but
before the bump leaves a structurally changed prefix with the old generation.
Subsequent startup can continue taking the unchanged fast path indefinitely.

Representative ordering:

```text
Keg#uninstall removes the keg before Overlay.sync!(mutation: true)
Keg#link and Keg#unlink mutate links before Overlay.bump_generation!
Formula installation creates package paths before its final generation bump
```

The final handoff explicitly lists real process-kill injection as unexecuted.
Generation files improve performance and drift detection but are not a
crash-consistent mutation journal.

**Required correction:** mark the prefix dirty before a mutation, publish the
new generation only after success, and force structural reconciliation while a
dirty marker exists. Recovery must clear the marker only after validating the
resulting package view.

### F8 — Medium: individually surfaced final directory is not checksum-complete

The complete delivery archive is intact and its SHA-256/checksum manifest pass.
However, the separately surfaced directory
`/mnt/data/brew-6.0.15-native-overlay-final` contains `SHA256SUMS` entries for 12
files that are absent, including the README, review file, Git-state file,
patch-series manifest, seven format patches, and restore script.

Executed result:

```text
sha256sum: WARNING: 12 listed files could not be read
```

This does not invalidate the complete archive, but the individual-file handoff
is not independently verifiable from its own checksum manifest.

## Checks actually executed

The following checks passed against the implementation tree or complete final
archive:

- policy composer self-test;
- final archive SHA-256 and complete extracted `SHA256SUMS` verification;
- Git bundle verification, `git fsck --full`, and an independent clone with
  matching implementation HEAD/tree;
- Bash syntax for changed shell files;
- Ruby syntax for changed Ruby files/specifications under the available Ruby;
- the four committed overlay shell suites;
- the five-case final audit reproducer;
- Git whitespace checks.

The committed happy-path and crash-state tests are useful but do not cover a
live transaction owner, repeated union-rack reconciliation, target validation,
or regular-file rollback effects.

## Static-only findings

F4, F6, and F7 are established from deterministic source control flow but were
not exercised through the complete Homebrew CLI. They must be converted into
Ruby/CLI regressions before release.

## Blocked checks

The environment does not contain Homebrew's requested Ruby 4.0.6 development
runtime and gem set. Dependency downloads are prohibited. Therefore the
following remain blocked:

- complete RSpec, RuboCop, and Sorbet runs;
- real bottle and source installations;
- real process-kill injection at transaction phases;
- concurrent `brew list`/`brew install` integration under the full CLI;
- representative filesystem tests for `renameat2(RENAME_EXCHANGE)`;
- cask behavior.

## Release gate

Do not deploy this fork as a shared package manager until F1–F5 are fixed and
covered by full CLI tests under the requested Ruby environment. F6 and F7
should also be closed before production; F8 should be corrected in the final
handoff. Until then, the implementation is suitable only for source review and
isolated experimentation with disposable prefixes.
