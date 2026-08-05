# Rigorous review: Homebrew 6.0.15 native per-user overlay

## Review target

- Branch: `overlay-store`
- Reviewed implementation HEAD: `18e50f0e289bcba89f85d5e10ad3f295c4481ba2`
- Reviewed implementation tree: `634ad66358d6f3501b96a0c0e698e62b9a850b3a`
- Clean native-only series base: `1c15944`
- Scope: the five native-overlay patches and their interaction with adjacent
  Homebrew formula, linking, migration, diagnostic, Bundle, and command paths.

## Verdict

**Reject for production deployment.** The direction is understandable and the
happy path works for simple formula fixtures, but the implementation is a
prototype rather than a safe Homebrew overlay. It has release-blocking error
propagation and transaction defects, a data-loss path in formula migration,
incomplete union-link semantics, unsafe diagnostics, and multi-second work on
every invocation. Several native Homebrew commands do not preserve their normal
semantics in an inherited overlay.

The Git artifacts are internally sound: the delivered bundle verifies, and the
clean five-patch series replays to the exact reviewed tree. Repository integrity
does not establish runtime correctness.

## Review method

The review used three evidence classes:

1. **Executed evidence** — shell-level adversarial fixtures, delivery checksum
   verification, exact Git patch replay, syntax checks, the committed shell
   fixture, and an illustrative synchronization benchmark.
2. **Static control-flow evidence** — direct inspection of all 17 changed files
   and adjacent unpatched Homebrew paths whose behavior is affected by inherited
   racks and links.
3. **Blocked checks** — the source requires Ruby 4.0.6 while the available
   runtime is Ruby 3.3.8; the complete native RSpec, RuboCop, and Sorbet
   dependency set was not present. No dependency downloads were used to fill
   that gap.

`Library/Homebrew/test/support/overlay_review_findings.sh` reproduces seven shell-level defects in a disposable
fixture. `Library/Homebrew/test/support/overlay_performance_smoke.sh` provides an illustrative, configurable
synchronization measurement.

## Release-blocking findings

### R1 — Critical: launcher and synchronizer suppress failures

**Code evidence**

- `bin/brew:184-185` calls `homebrew-overlay-bootstrap` without checking its
  status, and the launcher runs with `set -u`, not `set -e`.
- `Library/Homebrew/utils/overlay.sh:377-378` runs Cellar synchronization and
  then prefix-link synchronization without short-circuiting. The second result
  overwrites the first.
- `Library/Homebrew/utils/overlay.sh:401-404` unconditionally returns success
  after active synchronization.
- `Library/Homebrew/utils/overlay.sh:295-298` treats an unsafe destination
  parent as success, does not validate `ln`, and then may record state.
- `Library/Homebrew/utils/overlay.sh:190-193` can overwrite a failing launcher
  or config operation with the success status of the final `printf`.

**Executed evidence**

- An active overlay with a symlinked `Cellar` printed
  `user overlay Cellar is not a real directory` but returned status `0`.
- An unsafe `brew.env` symlink produced an explicit refusal message, while
  `homebrew-overlay-initialize-prefix` still returned status `0` and printed the
  prefix.
- A user `bin` path replaced by a symlink caused a required inherited executable
  not to be projected; synchronization returned `0` with no diagnostic.

**Impact**

A normal `brew` command can continue against a stale or partially synchronized
prefix after the overlay has detected an unsafe state. A mutating command can
then operate on a package view different from the one shown to dependency and
linking code. This defeats the safety checks the implementation appears to add.

**Required correction**

Every mutating operation must propagate failure explicitly. Build the complete
new Cellar/link state in staging, validate every link and directory, and publish
it atomically only after all operations succeed. Do not use an unconditional
`return 0`; do not treat a failed safe-mkdir as a successful omission.

### R2 — Critical: rack shadowing is not an atomic or recoverable transaction

**Code evidence**

- `Library/Homebrew/overlay.rb:108-120` replaces an inherited rack symlink with
  a real directory before installation. There is no durable transaction marker,
  staging rack, or startup recovery.
- `Library/Homebrew/formula_installer.rb:553-654` sets
  `overlay_rack_prepared` only after `prepare_formula_install!` returns. An
  exception inside preparation can leave the rack changed while the rescue path
  believes no preparation happened.
- `Library/Homebrew/formula_installer.rb:999-1092` performs linking,
  post-install, receipt updates, and other finishing work after the rack has
  become active.
- Normal link failures at `formula_installer.rb:1251-1277` call `ofail` but do
  not raise. Post-install failures at `formula_installer.rb:1407-1451` set
  `Homebrew.failed` but do not raise. Exception-only rollback therefore does not
  cover common failed installs.
- Dependency installation at `formula_installer.rb:888-958` has no inherited
  rack rollback corresponding to the top-level path.

**Executed evidence**

After replacing an inherited rack symlink with an empty real rack and running
normal synchronization, the rack remained real and the valid base keg was no
longer visible. This models interruption after preparation and before commit.

**Impact**

A signal, process kill, shell failure, link conflict, post-install failure, or
some dependency failures can leave an empty or partial local rack permanently
shadowing a working administrator package. The next invocation treats that
partial rack as intentional and does not repair it.

**Required correction**

Install into a uniquely named staging rack. Keep the inherited rack visible
until all install and finish phases succeed. Commit with an atomic rename under
the formula lock, record a durable transaction journal, and repair abandoned
transactions during bootstrap. Roll back on both exceptions and
`Homebrew.failed?`, including dependency installs.

### R3 — Critical: formula migration can delete local files before failing on an inherited target

**Static control-flow evidence**

For a local old-name rack and an inherited base new-name rack:

- `Library/Homebrew/migrator.rb:163-165` treats the inherited new-name symlink as
  an existing destination.
- `migrator.rb:271-291` recursively deletes files from the local old-name rack
  when corresponding files already exist under the inherited new-name rack.
- `migrator.rb:293-305` then moves remaining files through the new-name symlink,
  which resolves into the read-only administrator Cellar and can fail.
- Recovery at `migrator.rb:473-517` does not reconstruct files already deleted
  as conflicts when `new_cellar_existed` was true.

**Impact**

A rename/oldname migration can lose files from a developer-owned keg and still
fail to complete. This is a local data-loss path, not merely a stale link.

**Required correction**

Make `Migrator` overlay-aware. Never merge into an inherited rack. Localize the
new-name rack in staging first, preserve the old rack untouched until commit,
and use a reversible journal rather than deleting conflicts before the move has
succeeded.

### R4 — High: inherited directory links are removed instead of unioned

**Static control-flow evidence**

- Native Homebrew's normal conflict path at `Library/Homebrew/keg.rb:738-763`
  resolves a linked directory into its owning keg and materializes its entries
  before adding another formula.
- The overlay shortcut at `keg.rb:731-735` simply removes an inherited directory
  link and returns.
- `keg.rb:827-875` then creates a real destination directory for the upper keg,
  but the lower directory's entries have not been copied or linked into it.

Example: if base formula A supplies `include/x/a.h` through a directory link and
local formula B adds `include/x/b.h`, linking B can make `a.h` disappear from the
effective prefix. The next shell synchronization sees a real destination
folder and does not repopulate the missing lower entries.

**Impact**

Common merged namespaces such as `include`, `lib/pkgconfig`, `lib/cmake`,
completion directories, and portions of `share` can lose inherited files when a
local formula contributes to the same directory.

**Required correction**

Construct a real union directory before adding upper entries, preserving lower
entry ownership and conflict rules. Better, generate the complete effective
link tree in staging from package manifests and atomically switch generations.

### R5 — High: `brew doctor` recommends deleting the administrator Cellar

**Static control-flow evidence**

An active overlay intentionally has a user `HOMEBREW_PREFIX`, an
administrator-managed `HOMEBREW_REPOSITORY`, and a `Cellar` in both. The
unchanged diagnostic at `Library/Homebrew/diagnostic.rb:475-493` therefore
reports `You have multiple Cellars` and recommends:

```text
rm -rf <HOMEBREW_REPOSITORY>/Cellar
```

In the documented deployment, that path is the administrator's base Cellar.
`diagnostic.rb:1218-1231` also reports the user prefix as a non-default Homebrew
prefix, which is expected but not overlay-aware.

**Impact**

The official health-check command labels the designed state as broken and gives
a destructive remediation targeting the shared base installation.

**Required correction**

Disable incompatible native diagnostics when the overlay is active and replace
them with overlay-specific checks that verify base readability, user-prefix
ownership, transaction state, link generation, and base generation consistency.

### R6 — High: every command rebuilds the full projected prefix

**Code evidence**

- `bin/brew:181-185` runs bootstrap before normal command dispatch.
- `Library/Homebrew/utils/overlay.sh:301-364` removes recorded links, recursively
  scans `bin`, `sbin`, `include`, `lib`, `share`, `Frameworks`, `etc`, `opt`, and
  most of `var`, and rebuilds the state file on every invocation.
- This runs for read-only and fast commands as well as mutations.

**Executed evidence**

On the review host, an illustrative fixture with 500 inherited executable links
and 1,000 mutable-state directories took 3.01 seconds for initial synchronization
and 2.87 seconds for an unchanged second synchronization. These are
environment-specific smoke measurements, not universal benchmarks, but they
demonstrate linear work and large no-change overhead.

**Impact**

Shell startup through `brew shellenv`, `brew --prefix`, `brew list`, and all
ordinary commands can incur multi-second latency. Large `etc`/`var` trees make
performance and lock hold times progressively worse.

**Required correction**

Use a base generation identifier and an indexed manifest. Skip synchronization
when neither the base generation nor local package generation changed. Apply
incremental diffs after mutations and preserve fast read-only command paths.

## High-severity compatibility findings

### R7 — High: native Homebrew command semantics are only partially integrated

The patch modifies a small set of formula install/uninstall paths, but inherited
packages affect many other native commands:

- **`brew unlink` is not persistent.** `Library/Homebrew/cmd/unlink.rb:23-35`
  removes links, but the next launcher synchronization recreates inherited
  links. The documented native pattern `brew unlink foo && ... && brew link foo`
  is therefore broken. This was reproduced dynamically.
- **`brew postinstall` can target an inherited keg.**
  `Library/Homebrew/cmd/postinstall.rb:18-32` calls `install_etc_var` and the
  post-install path without localizing the formula first. It can write through
  base-derived paths or fail against the read-only base.
- **`brew bundle cleanup` includes inherited formulae.**
  `Library/Homebrew/bundle/subcommand/cleanup.rb:256-273` derives cleanup
  candidates from the effective installed set. Force cleanup batches them into
  one uninstall command at lines 165-171, while uninstall rejects the entire
  batch when any inherited keg is present. The Bundle code then prints an
  `Uninstalled` count without checking `Kernel.system` success.
- **Dependency rollback is incomplete.** The nested installer path at
  `formula_installer.rb:888-958` does not restore an inherited dependency rack
  after all failed finish states.
- **Dependent checks do not model fallback.**
  `Library/Homebrew/installed_dependents.rb:26-76` evaluates the currently
  visible local replacement. Removing that replacement may be rejected even
  when a compatible inherited base keg would immediately become visible.

**Impact**

The design does not yet provide the stated behavior of a normal native Homebrew
prefix layered over a base. Users must know a hidden list of commands and
failure modes that are unsafe or semantically different.

**Required correction**

Move overlay behavior below command-specific call sites into a coherent package
view, transaction layer, and link-generation abstraction. Every formula mutation
must either operate on a local realization or explicitly reject inherited input
before side effects.

### R8 — High: base state and local dependency graphs are not version-consistent

The implementation exposes administrator kegs and links directly. Separate base
and user locks are documented, but there is no generation snapshot, dependency
closure, or consistency check. An administrator upgrade/removal can change an
inherited dependency between two user commands or invalidate a local package
built against the previous base ABI.

Absolute paths embedded in inherited binaries, scripts, pkg-config files, CMake
metadata, and runtime configuration still refer to the base prefix. Projecting
symlinks into `~/.linuxbrew` does not relocate those references. Stateful
formulae may read or write base `etc`/`var` paths or fail because they are
read-only.

**Impact**

The apparent effective prefix is not a stable package environment. Local
packages can silently observe a different lower dependency set over time, and
inherited programs do not consistently use user-local mutable state.

**Required correction**

At minimum, record and validate a base generation for each local realization.
For stronger compatibility, use immutable base generations and rebuild or reject
local dependents when their lower dependency identities change. Explicitly
classify formulae whose runtime state or absolute paths cannot be safely
inherited.

## Medium- and low-severity findings

### R9 — Medium: overlay initialization overwrites user configuration

`Library/Homebrew/utils/overlay.sh:87-106` rewrites the complete
`~/.linuxbrew/etc/homebrew/brew.env`. Reinitialization removed an unrelated
`HOMEBREW_NO_ANALYTICS=1` setting in the executed fixture.

Store managed overlay settings separately, or update only explicitly owned keys
while preserving user content and comments.

### R10 — Medium: lexical state-file containment can escape the prefix

`Library/Homebrew/utils/overlay.sh:25-29` validates path strings lexically.
`overlay.sh:228-242` trusts the user-writable TSV path field. A state entry such
as `<prefix>/../outside-link` passes the prefix test and can remove a symlink
outside the prefix. The review fixture reproduced that deletion. This is a
same-user filesystem safety defect rather than a privilege escalation.

Store only normalized relative paths, reject `.`/`..` and symlinked parent
components, and use a structured, atomically replaced state format. TSV also
cannot represent tabs or newlines safely.

### R11 — Medium: base oldname/alias rack symlinks are exposed as installed racks

`Library/Homebrew/utils/overlay.sh:218-225` uses `-d`, which follows symlinks, so
base Cellar oldname links are projected. `Library/Homebrew/formula.rb:2618-2629`
and the fast list path accept inherited symlink racks. The review fixture showed
both `newname` and `oldname` projected.

Mirror only real base rack directories, and model Homebrew oldnames/aliases via
formula metadata rather than as additional installed racks.

### R12 — Low: the individually surfaced delivery directory is not self-contained

`SHA256SUMS` in the individually surfaced delivery directory references 12 files
that are absent there, including `patches/`, `logs/`, `git-state.txt`, and
`patch-series.txt`; `sha256sum -c` fails. The complete delivery tarball does
contain those files and verifies successfully.

Advertise either the complete tarball as the sole checksum root or provide a
manifest tailored to each surfaced artifact set.

## Test-quality review

The existing test additions prove selected happy paths but miss the defects
above:

- `Library/Homebrew/test/support/overlay_test.sh:2` runs with
  `set -euo pipefail`, unlike the production launcher. This makes shell function
  failures abort during the test even when production continues.
- `Library/Homebrew/test/overlay_spec.rb:24` stubs `sync!`, so the Ruby tests do
  not exercise the shell/Ruby transaction boundary.
- No committed test covers interrupted preparation, normal non-raising finish
  failures, unsafe destination parents, directory union behavior, migration,
  `brew doctor`, `brew unlink`, `brew postinstall`, Bundle cleanup, config
  preservation, aliases, state-path normalization, performance, or concurrent
  base changes.
- The previous CLI integration logs are useful evidence, but the exact
  integration harness and local formula fixtures were not included as a
  directly rerunnable test artifact in the individually surfaced directory.

A production gate should include process-kill injection at every transaction
phase, command-level tests for all mutators, a generated directory-conflict
matrix, base-generation race tests, and performance limits for unchanged
invocations.

## Positive observations

- The verified Git bundle has valid objects, and the clean five-patch series
  replays onto `1c15944` to the exact implementation tree.
- Inherited-only uninstall is guarded in both `Keg#uninstall` and the batch
  uninstall path.
- Cleanup/autoremove contains explicit inherited-keg exclusions in several
  direct paths.
- The synchronizer preserves a user-created replacement when its current
  symlink target differs from the recorded inherited target.
- The documentation openly discloses formula-only inheritance, noncanonical
  prefix bottle limitations, read-only taps, and the absence of cross-prefix
  locking.

These strengths are worth retaining, but they do not offset the release blockers.

## Recommended redesign boundary

Do not keep adding command-specific conditionals to this patch. Preserve native
Homebrew directory names, but introduce three explicit internal abstractions:

1. **Package view** — resolve local and inherited racks without representing
   transient or alias state as ordinary racks.
2. **Atomic mutation transaction** — stage, finish, validate, and atomically
   publish a local rack with durable recovery.
3. **Generated link generation** — build a complete union link tree from package
   manifests, then atomically switch generations using a base-generation stamp.

Until those are present and the native command matrix passes, deployment should
remain limited to disposable experimental hosts.
