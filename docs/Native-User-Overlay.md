# Native per-user overlay on Linux

This fork can use an administrator-managed Homebrew installation as a read-only
lower layer and automatically place a developer's changes in a normal Homebrew
prefix owned by that developer. It does not run a package-management service and
it does not add named environments.

The default layout is:

```text
/home/linuxbrew/.linuxbrew/        administrator prefix (read-only to developers)
~/.linuxbrew/                      developer prefix (writable by one developer)
├── bin/
├── Caskroom/
├── Cellar/
├── etc/
├── include/
├── lib/
├── opt/
├── sbin/
├── share/
└── var/
```

`~/.linuxbrew/Cellar` is a real directory. Formula racks supplied by the
administrator are symlinks inside that directory. Formulae installed or upgraded
by the developer use real racks in the same directory and shadow the corresponding
administrator rack.

There is no `brew env` command, environment manifest, separate user package cache,
or `~/.local/share/homebrew/envs` hierarchy.

## Enable the overlay

The administrator enables the feature in `/etc/homebrew/brew.env`:

```text
HOMEBREW_OVERLAY=1
HOMEBREW_OVERLAY_BASE_PREFIX=/home/linuxbrew/.linuxbrew
```

`HOMEBREW_OVERLAY_BASE_PREFIX` may be omitted when users always invoke `brew`
through that base prefix. Setting it explicitly makes the intended lower layer
clear.

The administrator prefix must be readable and executable by the developer group,
but not writable by it. For example:

```sh
sudo chown -R admin:dev /home/linuxbrew/.linuxbrew
sudo chmod -R u+rwX,g+rX,g-w,o-rwx /home/linuxbrew/.linuxbrew
sudo find /home/linuxbrew/.linuxbrew -type d -exec chmod g+s {} +
```

Add each developer to `dev`, then have them start a new login session so the group
membership takes effect.

When a developer invokes the administrator's `brew`, the launcher detects that the
base prefix is not writable, initializes `~/.linuxbrew`, and re-executes through
`~/.linuxbrew/bin/brew`. The local launcher remains a symlink to the
administrator-managed Homebrew repository, while package and configuration paths
come from the local prefix.

Initialize the shell normally:

```sh
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
```

The resulting `PATH` starts with `~/.linuxbrew/bin` and
`~/.linuxbrew/sbin`.

## Package behaviour

An inherited formula is visible through ordinary commands such as `brew list`,
`brew info`, dependency resolution, and `brew --prefix`. Its executable, `opt`
entry, linked-keg record, libraries, headers, and other linked files are surfaced
through the local prefix.

The main operations behave as follows:

| Operation | Result in a developer prefix |
| --- | --- |
| `brew install foo` when the base copy satisfies the request | Uses the inherited formula |
| `brew upgrade foo` or `brew reinstall foo` | Creates a real local rack that shadows the base rack |
| `brew uninstall foo` for a local copy | Removes the local rack and exposes the base copy again |
| `brew uninstall foo` for an inherited-only copy | Refuses to modify the administrator package |
| `brew cleanup` or `brew autoremove` | Skips inherited kegs |
| Administrator upgrades `foo` | Appears on the next invocation unless a local rack shadows it |

A failed local installation that started from an inherited formula discards its
partial local rack and restores the inherited rack.

The synchronizer records only the exact symlinks it generated in
`~/.linuxbrew/var/homebrew/overlay-links.tsv`. It removes a recorded link only when
the current target still matches that record, so a developer-created replacement
at the same path is preserved.

## Configuration

The following variables control the feature:

- `HOMEBREW_OVERLAY=1` enables automatic fallback.
- `HOMEBREW_OVERLAY_BASE_PREFIX` selects the read-only lower prefix.
- `HOMEBREW_OVERLAY_USER_PREFIX` changes the default `~/.linuxbrew` upper prefix.
- `HOMEBREW_OVERLAY_FORCE=1` selects the user prefix even when the invoking user
  can write the base prefix.

The generated `~/.linuxbrew/etc/homebrew/brew.env` records the base and user
prefixes and disables automatic updates. Homebrew code and shared taps therefore
remain administrator-managed.

The base and user prefixes must be absolute, disjoint paths. The user prefix,
its `Cellar`, and its `Caskroom` must be real directories rather than symlinks.

## Formula and cask scope

The inherited lower layer is formula-only. Base cask links are not copied into the
user prefix because casks have separate artifact and uninstall semantics and may
write outside Homebrew's prefix.

A developer can still run ordinary cask commands against the local prefix, subject
to the normal cask's destination and privilege requirements, but this feature does
not inherit or protect casks installed in the administrator prefix.

## Operational limits

- The user prefix is not Homebrew's canonical Linux prefix. Bottles that are not
  relocatable may need to build from source.
- The shared Homebrew repository and taps are read-only to developers. Run
  `brew update`, tap maintenance, and base upgrades as the administrator.
- Do not update the administrator prefix while a developer package mutation is in
  progress; base and user locks are intentionally separate in this non-service
  design.
- The lower package files are reused through symlinks. This design does not create
  hardlinks or deduplicate separate local builds.
- A local formula with the same rack name shadows the complete base rack, including
  other base versions of that formula, until the local rack is removed.

To disable automatic fallback, remove `HOMEBREW_OVERLAY=1` from the system
configuration. Remove `~/.linuxbrew` only after preserving any developer-installed
packages or configuration that must be kept.
