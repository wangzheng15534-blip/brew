# Native per-user overlay on Linux

This fork can use one administrator-managed Homebrew installation as a read-only
lower package layer while each developer writes to a second, ordinary Homebrew
prefix in their own home directory. It does not run a daemon, create named
environments, or introduce a separate package-store layout.

The default paths are deliberately native Linuxbrew paths:

```text
/home/linuxbrew/.linuxbrew/        administrator prefix; read-only to developers
~/.linuxbrew/                      developer prefix; owned and writable by one user
├── bin/
├── Caskroom/
├── Cellar/
├── etc/
├── Frameworks/
├── include/
├── lib/
├── opt/
├── sbin/
├── share/
└── var/
```

`XDG_DATA_HOME` does not affect the package prefix. Unless explicitly overridden
with `HOMEBREW_OVERLAY_USER_PREFIX`, the writable prefix is always
`$HOME/.linuxbrew`.

## Package view

`~/.linuxbrew/Cellar` is a real directory. For a formula that has no private
realization, its rack is a read-only symlink to the administrator rack:

```text
~/.linuxbrew/Cellar/cmake
    -> /home/linuxbrew/.linuxbrew/Cellar/cmake
```

When the developer installs another version, the rack becomes a real directory.
The private version is real and missing administrator versions are inherited as
version symlinks:

```text
~/.linuxbrew/Cellar/cmake/
├── 4.0.0 -> /home/linuxbrew/.linuxbrew/Cellar/cmake/4.0.0
└── 4.2.0/                         private developer keg
```

The private rack shadows the administrator's active `opt` and linked-keg records.
Removing the final private version restores the inherited rack and the
administrator's active selection.

Homebrew does **not** recursively copy or project the administrator's `bin`,
`lib`, `include`, or `share` trees into the user prefix. `brew shellenv` instead
places the two native executable prefixes in this order:

```text
~/.linuxbrew/bin
~/.linuxbrew/sbin
/home/linuxbrew/.linuxbrew/bin
/home/linuxbrew/.linuxbrew/sbin
```

Homebrew's formula resolver reaches inherited headers and libraries through the
inherited Cellar and `opt` records. The two general-purpose prefix link trees are
not treated as a filesystem union.

## Enable the overlay

Enable it in `/etc/homebrew/brew.env`:

```text
HOMEBREW_OVERLAY=1
HOMEBREW_OVERLAY_BASE_PREFIX=/home/linuxbrew/.linuxbrew
```

The administrator prefix must be readable and executable by the developer group
but not writable by that group. One example is:

```sh
sudo chown -R admin:dev /home/linuxbrew/.linuxbrew
sudo chmod -R u+rwX,g+rX,g-w,o-rwx /home/linuxbrew/.linuxbrew
sudo find /home/linuxbrew/.linuxbrew -type d -exec chmod g+s {} +
```

Add developers to `dev` and start a new login session after changing group
membership.

A developer continues to invoke the administrator launcher:

```sh
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
```

When the base prefix is not writable, the launcher initializes `~/.linuxbrew`,
creates `~/.linuxbrew/bin/brew` as a symlink to the administrator-managed
Homebrew repository, and re-executes from the user prefix. The generated managed
configuration is written to:

```text
~/.linuxbrew/etc/homebrew/overlay.env
```

It does not replace `~/.linuxbrew/etc/homebrew/brew.env`; developer-owned settings
in that file are preserved.

## Formula command behaviour

| Operation | Behaviour in the developer prefix |
| --- | --- |
| `brew install foo` when the inherited version satisfies the request | Reuses the administrator formula without copying it |
| `brew upgrade foo` or `brew reinstall foo` | Builds or pours a private realization and atomically publishes a real local rack |
| `brew uninstall foo` for a private version | Removes only the private keg and restores the administrator package when no private version remains |
| `brew uninstall foo` for an inherited-only formula | Refuses to modify the administrator package |
| `brew cleanup` and `brew autoremove` | Ignore inherited administrator kegs |
| `brew bundle cleanup` | Excludes inherited-only formulae from removal candidates |
| `brew link`, `brew unlink`, or `brew postinstall` on an inherited-only formula | Refuses the mutation; create a private realization first |
| Migration into a name already supplied by the base | Refuses before moving or deleting local files |

The overlay is formula-first. Administrator casks are not inherited because cask
artifacts can live outside the Homebrew prefix and have separate uninstall
semantics. A developer may still install a cask into their own prefix subject to
the cask's normal destinations and privilege requirements.

## Atomic private replacement

Replacing an inherited formula uses a durable transaction inside the user's
native Cellar:

1. Capture the current administrator package generation.
2. Build or pour into a private staging rack.
3. Relocate staging-prefix references to the final native Cellar path.
4. Prepare a complete replacement rack containing the private keg and inherited
   version links.
5. Revalidate the administrator generation.
6. Publish with Linux `renameat2(RENAME_EXCHANGE)` on the same filesystem.
7. Finish linking and post-install work.
8. Record the administrator generation in the private keg and commit.

The journal lives below:

```text
~/.linuxbrew/var/homebrew/overlay/transactions/
```

Startup recovers an interrupted transaction before exposing the package view. A
failed or non-raising Homebrew operation rolls back the unpublished or published
private rack and restores the inherited package.

## Package generations and startup synchronization

Both native prefixes contain an explicit package generation:

```text
/home/linuxbrew/.linuxbrew/var/homebrew/overlay-generation
~/.linuxbrew/var/homebrew/overlay-generation
```

The value is a validated 64-character hexadecimal token. The first writable
administrator invocation initializes its token from the current native package
view. Patched Homebrew package mutations then advance the corresponding token
after formula installation, linking, unlinking, uninstallation, and post-install
work.

A developer invocation compares these tokens with the last committed view stamp.
When they match and no recovery journal exists, startup skips Cellar traversal and
drift scanning. When either token changes, Homebrew rebuilds only the inherited
Cellar, `opt`, and linked-keg view and commits a new stamp.

Administrator package changes must be made through this patched `brew`. If an
administrator changes `Cellar`, `opt`, or `var/homebrew/linked` manually, advance
the base generation before developers rely on the overlay:

```sh
/home/linuxbrew/.linuxbrew/Homebrew/Library/Homebrew/utils/overlay.sh \
  --bump-generation /home/linuxbrew/.linuxbrew
```

Each private keg records the administrator generation against which it was
installed. A later base-generation change is reported by startup and `brew
doctor`; reinstall the reported private formulae before relying on binary or ABI
compatibility.

## Managed state

Overlay-owned state is confined to the user's prefix:

```text
~/.linuxbrew/var/homebrew/overlay/base-prefix
~/.linuxbrew/var/homebrew/overlay/view.state
~/.linuxbrew/var/homebrew/overlay/view.stamp
~/.linuxbrew/var/homebrew/overlay/base-drift.state
~/.linuxbrew/var/homebrew/overlay/transactions/
~/.linuxbrew/var/homebrew/overlay/sync/
```

`view.state` is a NUL-delimited map of normalized relative paths to exact
administrator targets. Synchronization removes a link only when the path remains
inside `~/.linuxbrew` and its current target still matches the recorded managed
target. A developer-created replacement is not deleted as stale overlay state.

The per-user synchronization lock is:

```text
~/.linuxbrew/var/homebrew/locks/overlay-sync.lock
```

It serializes user-view updates. It does not lock the administrator prefix.

## Configuration

- `HOMEBREW_OVERLAY=1` enables automatic fallback.
- `HOMEBREW_OVERLAY_BASE_PREFIX` selects the read-only administrator prefix.
- `HOMEBREW_OVERLAY_USER_PREFIX` optionally overrides the default
  `$HOME/.linuxbrew` user prefix.
- `HOMEBREW_OVERLAY_FORCE=1` selects the user prefix even when the invoking user
  can write the base prefix.

The base and user prefixes must be absolute and disjoint. The user prefix,
`Cellar`, and `Caskroom` must be real directories rather than symlinks.
Automatic Homebrew code and tap updates are disabled in an active user overlay;
run repository updates, tap maintenance, and base upgrades as the administrator.

## Operational boundaries

- `~/.linuxbrew` is not Homebrew's canonical Linux bottle prefix. Bottles that
  are not relocatable may need source builds.
- The generation protocol detects and rejects a base change during private
  publication, but it is not an immutable administrator snapshot. Do not perform
  administrator package mutations while developers are installing packages.
- A base-generation change conservatively marks all private formulae as needing
  review, even when the changed administrator formula appears unrelated.
- Direct filesystem edits that bypass patched Homebrew must be followed by an
  explicit generation bump.
- The lower package payload is reused with symlinks. This design does not create
  conda-style hardlinks or a content-addressed package cache.
- The shared Homebrew repository and shared taps remain administrator-managed and
  read-only to developers.

To disable automatic fallback, remove `HOMEBREW_OVERLAY=1` from the system
configuration. Preserve any developer-installed packages and configuration before
removing `~/.linuxbrew`.
