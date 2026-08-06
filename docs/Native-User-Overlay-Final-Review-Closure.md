# Final native-overlay review closure

This document records the disposition of findings F1–F8 from
[Final native overlay review](Native-User-Overlay-Final-Review.md). That review
assessed implementation commit `3ec474c` and remains a historical record. Its
production-rejection verdict does not describe the corrected implementation.

The implementation continues to use two ordinary native Homebrew prefixes:

```text
administrator: /home/linuxbrew/.linuxbrew
user:          $HOME/.linuxbrew
```

There is no package-management daemon, named environment hierarchy, claims
database, or separate package cache.

A finding is **closed** below when the reviewed failure mode is prevented by
current code and a focused committed regression covers it. Artifact finding F8
is closed only when the delivery generated from the final HEAD passes its own
fresh-extraction checksum and restore gate.

## F1 — live transactions were recovered as abandoned: closed

A formula transaction now holds a dedicated advisory owner lock from startup
through commit or rollback. Startup recovery attempts that lock nonblockingly
and never deletes a journal or staging tree while the lock is held. Recovery does
not trust a PID as proof of ownership.

Transaction startup was hardened further after the audit:

1. acquire the owner lock;
2. acquire the global mutation lock and write the dirty-generation marker;
3. validate the base and inherited rack;
4. write a complete journal under `transactions/.new-<id>`;
5. fsync and atomically rename it to `transactions/<id>`;
6. create staging data.

A live pending journal blocks startup. An abandoned pending journal and orphan
owner lock are removed after their lock becomes available. An incomplete visible
journal remains a hard error.

Evidence:

- `Library/Homebrew/overlay.rb`
- `Library/Homebrew/utils/overlay.sh`
- `overlay_transaction_recovery_test.sh`
- `overlay_spec.rb`

## F2 — version-union reconciliation oscillated: closed

Every expected inherited child remains in the desired map on every
reconciliation. An unchanged second or third synchronization is a fixed point;
it no longer alternately removes and recreates inherited versions.

Evidence:

- target construction in `homebrew-overlay-build-view`
- `overlay_view_reconciliation_test.sh`
- final review regression gate

## F3 — inherited children were not target-validated or managed: closed

Reconciliation distinguishes exactly three valid states at an administrator
version name:

- missing: create and record the exact inherited link;
- exact inherited symlink: retain and record it;
- real local directory: treat it as an intentional private shadow.

Any other symlink, regular file, or unsupported object is a hard conflict.
Transaction-created inherited children use the same desired-state validation,
so removed administrator versions do not leave unmanaged broken children.

Evidence: `overlay_view_reconciliation_test.sh` covers wrong targets,
transaction-created links, administrator removal, and repeated passes.

## F4 — force uninstall rejected mixed racks: closed

Force uninstall partitions each rack into private and inherited kegs. It passes
only private kegs to native removal, preserves inherited versions, and reports an
inherited-only request instead of attempting to modify the base. Brewfile force
cleanup uses the same behavior.

Evidence:

- `Library/Homebrew/uninstall.rb`
- `overlay_removal_partition_test.sh`
- uninstall and Bundle specifications

## F5 — rollback left external side effects: closed by commit-boundary change

The implementation no longer claims to make arbitrary Homebrew link and
post-install effects transactional. The durable private-keg boundary now occurs
before link, service, `etc`, `var`, and formula post-install operations.

Before that boundary, failure discards the private keg or restores the inherited
rack. After that boundary, failure leaves the private package installed, matching
native Homebrew's installed-but-unlinked or post-install-failed state. The lower
rack is not restored underneath regular-file or formula-specific side effects
that cannot be universally reversed.

The remaining guarantee is precise: **Cellar rack publication is atomic; the
whole formula installation is not universally atomic.**

Evidence:

- `Library/Homebrew/formula_installer.rb`
- `overlay_commit_boundary_test.sh`
- installer control-flow specifications

## F6 — autoremove protected valid private candidates: closed

Autoremove builds its candidate and dependent graph from private kegs while
retaining inherited formulae as available fallback. A private package can be
autoremoved even when the administrator prefix provides another version.

Evidence:

- `Library/Homebrew/cleanup.rb`
- `overlay_removal_partition_test.sh`
- cleanup specifications

## F7 — generations were not crash-consistent: closed

Every patched native mutation acquires a per-prefix global mutation lock and
writes `overlay-generation.dirty` before its first filesystem change. Successful
completion publishes a new generation and removes the marker. A killed process
releases its kernel lock but leaves the marker, forcing structural reconciliation
on the next invocation.

A caller-supplied mutation-owner token is accepted only while the matching
advisory lock is held and contains that token. Symlinked intermediate lock,
journal, staging, and replacement directories are rejected.

Evidence:

- mutation ownership in `Library/Homebrew/overlay.rb`
- dirty-generation recovery in `Library/Homebrew/utils/overlay.sh`
- `overlay_generation_recovery_test.sh`
- mutation ownership and path-hardening specifications

## F8 — surfaced delivery was incomplete: final-delivery gate

The previous convenience directory referenced absent files. The replacement
handoff must have one actual checksum root containing every file named in its
`SHA256SUMS`, including:

- the exact verified Git bundle and bundle checksum;
- net patch and atomic format-patch series;
- exact source archive;
- current documentation and review closure;
- verification log, Git state, patch manifest, handoff manifest, and blockers;
- a restore-and-verify script.

The release procedure extracts the delivery into a new directory, runs
`sha256sum -c SHA256SUMS`, restores the bundle, compares HEAD and tree, replays
the net patch and atomic series, and compares the source archive tree. F8 is
closed only by a delivery that passes those checks; source changes alone cannot
close an artifact finding.

## Additional control-flow correction

The post-audit pass also found that non-raising `Homebrew.failed?` handling was
scoped only to inherited-rack replacements. Every user-prefix formula install
now receives an isolated failure scope. A failure before the durable boundary
discards a newly created uncommitted private keg and cannot be hidden by an
earlier batch failure.

## Current committed regression gate

`overlay_final_review_reproducer.sh` is now a release regression gate rather
than a vulnerability reproducer. It runs focused coverage for:

- live, pending, abandoned, incomplete, published, committing, and recovery
  transaction states;
- convergent exact-target version unions;
- private-only force uninstall and autoremove partitioning;
- the durable package boundary;
- dirty-generation crash recovery and live-owner exclusion.

The original adversarial review suite, native package-view integration, and
unchanged-startup performance smoke remain part of the offline matrix.

## Target-host acceptance still required

The available offline checks do not replace Homebrew's supported development
matrix. Before broad production deployment, run at least:

- complete RSpec, RuboCop, and Sorbet under Homebrew's requested Ruby 4.0.6 and
  development gem set;
- representative real bottle and source installations;
- process-kill injection at each real installer transaction phase;
- concurrent command testing on the deployment filesystem;
- `renameat2(RENAME_EXCHANGE)` tests on every supported architecture/filesystem;
- administrator-generation race testing;
- cask tests for user-prefix behavior, while keeping base-cask inheritance
  disabled.

No dependency may be silently downloaded or substituted merely to report those
checks as passing.
