---
last_review_date: "2026-08-05"
---

# Overlay Environments on Linux

This fork provides an optional, non-service overlay for a read-only, administrator-managed Homebrew installation on Linux.
It is intended for trusted development hosts where administrators manage a shared base and developers need writable, isolated formula environments.
It does not turn the upstream Homebrew multi-user layout into a supported upstream configuration.

## Filesystem model

The administrator-managed base remains a normal Homebrew prefix, normally `/home/linuxbrew/.linuxbrew`.
A developer who cannot write to that prefix is automatically redirected to a per-user environment when `HOMEBREW_OVERLAY` is enabled.

The default layout is:

```text
/home/linuxbrew/.linuxbrew/                         administrator-managed base prefix
├── Cellar/                                        base formula kegs
├── bin/
├── opt/
└── var/homebrew/linked/

/develop/homebrew/envs/<shared-environment>/       optional administrator-managed parent prefix
├── Cellar/
├── bin/
├── opt/
└── var/homebrew/linked/

${XDG_DATA_HOME:-$HOME/.local/share}/homebrew/
├── envs/<environment>/                            developer-owned environment prefix
│   ├── Cellar -> ../../pkgs/<environment>/Cellar
│   ├── bin/
│   ├── opt/
│   ├── etc/homebrew/brew.env
│   └── var/homebrew/linked/
└── pkgs/<environment>/Cellar/                     developer-owned formula kegs
```

Each user environment has its own writable Cellar.
This deliberately differs from a single Conda-style package cache because Homebrew uninstall and cleanup operations remove complete keg directories.
Keeping user Cellars separate prevents one environment from deleting a keg used by another environment.

`~/.cache/Homebrew` remains the download and build cache.
Do not place the persistent user Cellar under a directory that routine cache cleanup may remove.

## Automatic selection

Set `HOMEBREW_OVERLAY=1` in `/etc/homebrew/brew.env` or the base prefix's `etc/homebrew/brew.env`:

```sh
HOMEBREW_OVERLAY=1
HOMEBREW_OVERLAY_BASE_PREFIX=/home/linuxbrew/.linuxbrew
HOMEBREW_OVERLAY_SHARED_ENV_DIR=/develop/homebrew/envs
```

The launcher then follows these rules:

1. An administrator who can write to the base prefix continues to use the base directly.
2. A developer who cannot write to the base is redirected to the selected user environment.
3. The selected user environment is created on first use.
4. The user environment's `Cellar` points to its private package Cellar.
5. Read-only parent racks and public links are synchronised into the user environment.
6. The command is restarted through the user environment's `bin/brew` symlink while using the administrator-managed Homebrew code checkout.

Set `HOMEBREW_OVERLAY_FORCE=1` to force an overlay even when the caller can write to the base.
This is useful for testing or for an administrator who wants a private development environment.

Select a named user environment with:

```sh
export HOMEBREW_OVERLAY_ENV=project-a
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
```

Environment names may contain ASCII letters, numbers, `.`, `_` and `-` and must start with a letter or number.

## Parent precedence

The active user environment always has highest precedence.
An optional shared environment has precedence over the base.

Select one shared environment with:

```sh
export HOMEBREW_OVERLAY_SHARED_ENV=llvm
```

This produces the parent order:

```text
user environment
shared environment: /develop/homebrew/envs/llvm
base: /home/linuxbrew/.linuxbrew
```

Administrators may set an explicit highest-precedence-first parent list instead:

```sh
HOMEBREW_OVERLAY_PARENT_PREFIXES=/develop/homebrew/envs/cuda:/develop/homebrew/envs/llvm:/home/linuxbrew/.linuxbrew
```

Every parent must be a complete, readable Homebrew-style prefix with its own `Cellar`, `bin`, `opt` and `var/homebrew/linked` views.
A parent Cellar may itself be a symlink to an administrator-managed package location, e.g. `/develop/homebrew/pkgs/<environment>/Cellar`.

## Formula behaviour

Inherited formulae are visible to formula discovery, dependency resolution, `brew list` and `brew list --versions`.
They remain stored in their administrator-managed parent.

The mutation rules are:

- `brew install <formula>` reuses an inherited formula when the selected version already satisfies the request.
- `brew upgrade <formula>` or `brew reinstall <formula>` creates a writable realization in the active user's Cellar and shadows every parent realization of the same formula.
- `brew uninstall <formula>` rejects removal when only an inherited realization is selected.
- Uninstalling the local realization exposes the highest-precedence inherited realization again in the same command.
- A failed install, upgrade or reinstall restores the inherited rack and public links.
- `brew cleanup` and `brew autoremove` skip inherited kegs and inherited reinstall backups.

The active prefix contains a generated public link view for `bin`, `sbin`, `include`, `lib`, `share`, `Frameworks`, `opt` and `var/homebrew/linked`.
User-created links and local-keg links win over inherited links.
The synchroniser records only links it created and removes a recorded link only while its target still matches, so it does not delete a later user replacement.

## Administrator setup

Create readable, non-writable shared roots for the development group:

```sh
sudo install -d -o admin -g dev -m 2750 /develop/homebrew
sudo install -d -o admin -g dev -m 2750 /develop/homebrew/envs
sudo install -d -o admin -g dev -m 2750 /develop/homebrew/pkgs
```

The leading `2` sets the set-group-ID bit on each directory so newly created entries inherit group `dev`.
Mode `2750` gives the group read and traversal access without write access.
Do not apply `chmod -R 2750` to an existing tree because that would mark ordinary files executable.

The base and shared prefixes must be readable and traversable by the developer group and writable only by their administrator.
The Homebrew code checkout used by `bin/brew` must also be readable by developers.

A typical administrator environment uses:

```sh
umask 0027
```

Developers' environment and package roots are created with private permissions under their own data directory.
No daemon, privileged broker or group-writable package prefix is required for developer commands.

## Environment variables

The public configuration variables are:

| Variable | Purpose |
| --- | --- |
| `HOMEBREW_OVERLAY` | Enable automatic overlay selection. |
| `HOMEBREW_OVERLAY_BASE_PREFIX` | Select the read-only base prefix. |
| `HOMEBREW_OVERLAY_ENV` | Select the per-user environment name, default `default`. |
| `HOMEBREW_OVERLAY_FORCE` | Enter the overlay even when the base is writable. |
| `HOMEBREW_OVERLAY_SHARED_ENV` | Select one administrator-managed shared parent. |
| `HOMEBREW_OVERLAY_SHARED_ENV_DIR` | Select the shared environment root, default `/develop/homebrew/envs`. |
| `HOMEBREW_OVERLAY_PARENT_PREFIXES` | Set an explicit colon-separated parent order. |
| `HOMEBREW_OVERLAY_USER_ENV_DIR` | Override the per-user environment root. |
| `HOMEBREW_OVERLAY_USER_PACKAGE_DIR` | Override the per-user package root. |

`HOMEBREW_OVERLAY_ACTIVE` and `HOMEBREW_OVERLAY_USER_CELLAR` are internal values written into the generated environment's `brew.env` file.

## Updates and locks

Overlay environments set `HOMEBREW_NO_AUTO_UPDATE=1`.
A developer command therefore does not attempt to update the administrator-managed Homebrew checkout or shared taps.
Administrators update the base checkout and shared metadata separately.

The overlay synchroniser uses a per-environment lock under `var/homebrew/locks` when `flock` is available.
This serialises link-tree regeneration without requiring a service.

## Current limits

This implementation is formula-first.
Arbitrary casks can write outside the active prefix or invoke external installers, so the overlay does not provide cask filesystem isolation.
System casks should remain administrator-managed.

Taps and the Homebrew code checkout remain administrator-managed.
This version does not provide a per-user tap fallback, so a developer cannot modify a read-only shared tap checkout through `brew tap`.

The user environment has a non-default prefix.
Relocatable bottles can normally be poured, but a bottle that requires the canonical Linux prefix may be unavailable and require a source build.
This implementation does not create a mount namespace that presents each environment as `/home/linuxbrew/.linuxbrew`.

Commands that intentionally rewrite an inherited formula's receipt or parent keg are not supported.
Install, upgrade, reinstall, uninstall, cleanup and formula listing contain explicit overlay handling, but arbitrary developer commands may still assume one writable Cellar.

Base or shared-environment upgrades change the inherited realization seen after the next overlay synchronisation.
A local user realization continues to shadow the changed parent until it is uninstalled.
