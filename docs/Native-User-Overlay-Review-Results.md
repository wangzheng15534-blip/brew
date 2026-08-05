# Native overlay review results

## Target before adding this review

```text
branch=overlay-store
implementation_head=18e50f0e289bcba89f85d5e10ad3f295c4481ba2
implementation_tree=634ad66358d6f3501b96a0c0e698e62b9a850b3a
base=1c15944
```

## Executed checks

| Check | Result |
| --- | --- |
| `verified_web_environment.py --self-test` | PASS |
| Bash syntax for changed shell files and review scripts | PASS |
| Ruby syntax for all implementation Ruby files changed from `1c15944` | PASS under Ruby 3.3.8, with upstream forward-compatibility warnings |
| Existing `overlay_test.sh` happy-path fixture | PASS |
| Adversarial shell reproducer | PASS as a review harness; all 7 expected defects reproduced |
| `git diff --check` before review commit | PASS |
| Clean five-patch replay onto `1c15944` | PASS; replay tree exactly matched `634ad66358d6f3501b96a0c0e698e62b9a850b3a` |
| Delivered bundle object verification and independent clone | PASS |
| Complete delivery tarball `sha256sum -c` | PASS |
| Individually surfaced delivery directory `sha256sum -c` | FAIL; 12 referenced files absent |

## Adversarial reproducer summary

```text
CONFIRMED: bootstrap suppresses failed synchronization
CONFIRMED: empty or interrupted local rack hides base indefinitely
CONFIRMED: reinitialization destroys unrelated user configuration
CONFIRMED: inherited unlink state is not persistent
CONFIRMED: synchronizer succeeds while omitting a required inherited link
CONFIRMED: state cleanup can remove a symlink outside the prefix
CONFIRMED: base alias/oldname symlink is exposed as an installed rack
confirmed=7 expected=7
```

Run with:

```sh
Library/Homebrew/test/support/overlay_review_findings.sh /path/to/repository
```

## Illustrative synchronization smoke result

The committed benchmark defaults to 500 inherited executable links and 1,000
base mutable-state directories. On the review host:

```text
links=500 directories=1000
first_elapsed=3.01 first_user=2.46 first_sys=0.68 maxrss_kb=3404
second_elapsed=2.87 second_user=2.36 second_sys=0.59 maxrss_kb=3536
```

Run with:

```sh
Library/Homebrew/test/support/overlay_performance_smoke.sh /path/to/repository
```

Counts can be changed with `LINK_COUNT` and `DIRECTORY_COUNT`. This is an
illustrative scaling smoke test, not a portable performance threshold.

## Patch replay

The five clean native patches were replayed onto the exact base commit with a
local review committer identity. Commit IDs changed because `git am` created new
commits, but the resulting source tree was exact:

```text
replay_head=5989ef0805290e7965cabdb65095fd1d394146cc
replay_tree=634ad66358d6f3501b96a0c0e698e62b9a850b3a
canonical_implementation_tree=634ad66358d6f3501b96a0c0e698e62b9a850b3a
```

## Blocked checks

- Homebrew's requested Ruby is `4.0.6`; the available runtime is Ruby `3.3.8`.
- The complete native RSpec, RuboCop, and Sorbet dependency set was not present.
- ShellCheck was not installed.
- Real bottle/source installation, arbitrary casks, process-kill injection into
  the Ruby installer, and concurrent administrator updates were not executed.
- A native `brew doctor` integration run was not accepted as evidence because
  the available compatibility runtime attempted to resolve missing local gems
  and API metadata. The dangerous multiple-Cellar remediation is established by
  direct static control flow in `Library/Homebrew/diagnostic.rb`.

No dependencies were downloaded to bypass these blockers.
