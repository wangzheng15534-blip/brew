# Homebrew's optional non-service, native-layout user overlay.
# Keep environment variable names in sync with Library/Homebrew/env_config.rb.

homebrew-overlay-truthy() {
  case "${1:-}" in
    1 | true | TRUE | yes | YES | on | ON) return 0 ;;
    *) return 1 ;;
  esac
}

homebrew-overlay-expand-home() {
  case "$1" in
    "~") printf '%s\n' "${HOME}" ;;
    "~/"*) printf '%s/%s\n' "${HOME}" "${1#\~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

homebrew-overlay-prefix-writable() {
  local prefix="$1"
  [[ -d "${prefix}" && -w "${prefix}" ]] || return 1
  [[ ! -e "${prefix}/Cellar" || -w "${prefix}/Cellar" ]]
}

homebrew-overlay-path-under() {
  local path="$1"
  local root="$2"
  [[ "${path}" == "${root}" || "${path}" == "${root}/"* ]]
}

homebrew-overlay-resolve-link() {
  local path="$1"
  local target target_directory target_basename
  target="$(readlink "${path}")" || return 1
  if [[ "${target}" == /* ]]
  then
    printf '%s\n' "${target}"
    return 0
  fi

  target_directory="${target%/*}"
  target_basename="${target##*/}"
  if [[ "${target_directory}" == "${target}" ]]
  then
    target_directory="."
  elif [[ -z "${target_directory}" ]]
  then
    target_directory="/"
  fi

  (
    CDPATH='' cd -- "${path%/*}" || exit
    CDPATH='' cd -- "${target_directory}" 2>/dev/null || exit
    printf '%s/%s\n' "$(pwd -P)" "${target_basename}"
  )
}

homebrew-overlay-default-user-prefix() {
  homebrew-overlay-expand-home "${HOMEBREW_OVERLAY_USER_PREFIX:-${HOME}/.linuxbrew}"
}

homebrew-overlay-safe-mkdir() {
  local prefix="$1"
  local directory="$2"
  local relative component current
  local -a components=()

  homebrew-overlay-path-under "${directory}" "${prefix}" || return 1
  [[ -d "${prefix}" && ! -L "${prefix}" ]] || return 1

  relative="${directory#"${prefix}"}"
  relative="${relative#/}"
  current="${prefix}"
  IFS=/ read -r -a components <<<"${relative}"
  for component in "${components[@]}"
  do
    [[ -n "${component}" && "${component}" != "." && "${component}" != ".." ]] || continue
    current="${current}/${component}"
    if [[ -L "${current}" || ( -e "${current}" && ! -d "${current}" ) ]]
    then
      return 1
    fi
    [[ -d "${current}" ]] || mkdir "${current}"
  done
}

homebrew-overlay-write-prefix-config() {
  local prefix="$1"
  local base_prefix="$2"
  local environment_file="${prefix}/etc/homebrew/brew.env"

  homebrew-overlay-safe-mkdir "${prefix}" "${environment_file%/*}" || return 1
  if [[ -L "${environment_file}" || ( -e "${environment_file}" && ! -f "${environment_file}" ) ]]
  then
    echo "Error: refusing to replace unsafe Homebrew configuration: ${environment_file}" >&2
    return 1
  fi
  cat >"${environment_file}" <<EOF_ENV
HOMEBREW_OVERLAY=1
HOMEBREW_OVERLAY_ACTIVE=1
HOMEBREW_OVERLAY_BASE_PREFIX=${base_prefix}
HOMEBREW_OVERLAY_USER_PREFIX=${prefix}
HOMEBREW_NO_AUTO_UPDATE=1
EOF_ENV
  chmod 0600 "${environment_file}"
}

homebrew-overlay-initialize-prefix() {
  local base_prefix="$1"
  local repository="$2"
  local prefix="$3"
  local brew_link="${prefix}/bin/brew"
  local brew_target="${repository}/bin/brew"
  local marker="${prefix}/var/homebrew/overlay-base-prefix"
  local existing_base=""

  if [[ "${prefix}" != /* || "${base_prefix}" != /* ]]
  then
    echo "Error: overlay prefixes must be absolute paths" >&2
    return 1
  fi

  if [[ "${prefix}" == "${base_prefix}" ]] ||
     homebrew-overlay-path-under "${prefix}" "${base_prefix}" ||
     homebrew-overlay-path-under "${base_prefix}" "${prefix}"
  then
    echo "Error: user and administrator prefixes must be disjoint: ${prefix}, ${base_prefix}" >&2
    return 1
  fi

  if [[ -L "${prefix}" || ( -e "${prefix}" && ! -d "${prefix}" ) ]]
  then
    echo "Error: user overlay prefix is not a real directory: ${prefix}" >&2
    return 1
  fi

  if [[ ! -d "${prefix}" ]]
  then
    mkdir -m 0700 -p "${prefix}"
  fi
  [[ -w "${prefix}" ]] || {
    echo "Error: user overlay prefix is not writable: ${prefix}" >&2
    return 1
  }

  local directory
  for directory in \
    bin Caskroom Cellar etc/homebrew Frameworks include lib opt sbin share \
    var/homebrew/linked var/homebrew/locks
  do
    homebrew-overlay-safe-mkdir "${prefix}" "${prefix}/${directory}" || {
      echo "Error: unsafe path inside user overlay prefix: ${prefix}/${directory}" >&2
      return 1
    }
  done

  if [[ -L "${prefix}/Cellar" ]]
  then
    echo "Error: the native user Cellar must be a real directory: ${prefix}/Cellar" >&2
    return 1
  fi

  if [[ -L "${marker}" || ( -e "${marker}" && ! -f "${marker}" ) ]]
  then
    echo "Error: refusing to use unsafe overlay marker: ${marker}" >&2
    return 1
  elif [[ -r "${marker}" ]]
  then
    IFS= read -r existing_base <"${marker}" || true
    if [[ "${existing_base}" != "${base_prefix}" ]]
    then
      echo "Error: ${prefix} already overlays ${existing_base}, not ${base_prefix}" >&2
      return 1
    fi
  else
    printf '%s\n' "${base_prefix}" >"${marker}"
    chmod 0600 "${marker}"
  fi

  if [[ -e "${brew_link}" && ! -L "${brew_link}" ]]
  then
    echo "Error: refusing to replace non-symlink brew launcher: ${brew_link}" >&2
    return 1
  fi
  if [[ -L "${brew_link}" && "$(readlink "${brew_link}")" != "${brew_target}" ]]
  then
    echo "Error: refusing to replace a brew launcher for another repository: ${brew_link}" >&2
    return 1
  fi
  ln -sfn "${brew_target}" "${brew_link}"

  homebrew-overlay-write-prefix-config "${prefix}" "${base_prefix}"
  printf '%s\n' "${prefix}"
}

homebrew-overlay-sync-cellar() {
  local user_cellar="$1"
  local base_cellar="$2"
  local rack target

  [[ -d "${user_cellar}" && ! -L "${user_cellar}" ]] || {
    echo "Error: user overlay Cellar is not a real directory: ${user_cellar}" >&2
    return 1
  }

  # Rebuild only inherited rack links. Real user racks and unrelated symlinks
  # are never removed by the synchronizer.
  for rack in "${user_cellar}"/*
  do
    [[ -L "${rack}" ]] || continue
    target="$(homebrew-overlay-resolve-link "${rack}" 2>/dev/null || true)"
    if [[ -z "${target}" ]] || homebrew-overlay-path-under "${target}" "${base_cellar}"
    then
      rm -f "${rack}"
    fi
  done

  [[ -d "${base_cellar}" ]] || return 0
  for rack in "${base_cellar}"/*
  do
    [[ -d "${rack}" ]] || continue
    [[ "${rack##*/}" == .* ]] && continue
    [[ -e "${user_cellar}/${rack##*/}" || -L "${user_cellar}/${rack##*/}" ]] || \
      ln -s "${rack}" "${user_cellar}/${rack##*/}"
  done
}

homebrew-overlay-remove-recorded-links() {
  local prefix="$1"
  local state_file="$2"
  local path target

  [[ -r "${state_file}" ]] || return 0
  while IFS=$'\t' read -r path target
  do
    [[ -n "${path}" && -n "${target}" ]] || continue
    homebrew-overlay-path-under "${path}" "${prefix}" || continue
    if [[ -L "${path}" && "$(readlink "${path}")" == "${target}" ]]
    then
      rm -f "${path}"
    fi
  done <"${state_file}"
}

homebrew-overlay-record-link() {
  local state_file="$1"
  local path="$2"
  local target="$3"
  printf '%s\t%s\n' "${path}" "${target}" >>"${state_file}"
}

homebrew-overlay-rewrite-link-target() {
  local target="$1"
  local base_prefix="$2"
  local user_prefix="$3"

  case "${target}" in
    "${base_prefix}") printf '%s\n' "${user_prefix}" ;;
    "${base_prefix}/"*) printf '%s/%s\n' "${user_prefix}" "${target#"${base_prefix}/"}" ;;
    *) printf '%s\n' "${target}" ;;
  esac
}

homebrew-overlay-base-link-shadowed() {
  local source="$1"
  local base_cellar="$2"
  local user_cellar="$3"
  local real relative rack

  real="$(readlink -f "${source}" 2>/dev/null || true)"
  [[ -n "${real}" ]] || return 1
  homebrew-overlay-path-under "${real}" "${base_cellar}" || return 1

  relative="${real#"${base_cellar}/"}"
  rack="${relative%%/*}"
  [[ -n "${rack}" && -e "${user_cellar}/${rack}" && ! -L "${user_cellar}/${rack}" ]]
}

homebrew-overlay-base-cask-link() {
  local source="$1"
  local base_caskroom="$2"
  local real

  real="$(readlink -f "${source}" 2>/dev/null || true)"
  [[ -n "${real}" ]] || return 1
  homebrew-overlay-path-under "${real}" "${base_caskroom}"
}

homebrew-overlay-link-file() {
  local prefix="$1"
  local destination="$2"
  local target="$3"
  local state_file="$4"

  [[ -e "${destination}" || -L "${destination}" ]] && return 0
  homebrew-overlay-safe-mkdir "${prefix}" "${destination%/*}" || return 0
  ln -s "${target}" "${destination}"
  homebrew-overlay-record-link "${state_file}" "${destination}" "${target}"
}

homebrew-overlay-sync-prefix-links() {
  local prefix="$1"
  local base_prefix="$2"
  local user_cellar="${prefix}/Cellar"
  local base_cellar="${base_prefix}/Cellar"
  local base_caskroom="${base_prefix}/Caskroom"
  local state_file="${prefix}/var/homebrew/overlay-links.tsv"
  local temporary_state="${state_file}.tmp.$$"
  local root source relative destination target

  homebrew-overlay-safe-mkdir "${prefix}" "${state_file%/*}" || return 1
  homebrew-overlay-remove-recorded-links "${prefix}" "${state_file}"
  : >"${temporary_state}"

  for root in bin sbin include lib share Frameworks etc opt var
  do
    [[ -d "${base_prefix}/${root}" ]] || continue
    while IFS= read -r -d '' source
    do
      relative="${source#"${base_prefix}/"}"
      case "${relative}" in
        bin/brew | etc/homebrew/brew.env | var/homebrew | var/homebrew/* | var/log | var/log/*)
          continue
          ;;
      esac

      destination="${prefix}/${relative}"
      if [[ -L "${source}" ]]
      then
        # Casks have separate artifact and uninstall semantics. Keep the user
        # Caskroom native and private; this overlay inherits formula links only.
        homebrew-overlay-base-cask-link "${source}" "${base_caskroom}" && continue
        homebrew-overlay-base-link-shadowed "${source}" "${base_cellar}" "${user_cellar}" && continue
        target="$(readlink "${source}")"
        target="$(homebrew-overlay-rewrite-link-target "${target}" "${base_prefix}" "${prefix}")"
        homebrew-overlay-link-file "${prefix}" "${destination}" "${target}" "${temporary_state}"
      elif [[ -d "${source}" ]]
      then
        [[ -e "${destination}" || -L "${destination}" ]] || \
          homebrew-overlay-safe-mkdir "${prefix}" "${destination}" || true
      fi
    done < <(find "${base_prefix}/${root}" -mindepth 1 \
      \( -path "${base_prefix}/var/homebrew" -o -path "${base_prefix}/var/log" \) -prune -o -print0)
  done

  # Homebrew's linked-keg records live below var/homebrew, whose other state
  # (locks, pins and metadata) must remain private to the user prefix.
  if [[ -d "${base_prefix}/var/homebrew/linked" ]]
  then
    for source in "${base_prefix}/var/homebrew/linked"/*
    do
      [[ -L "${source}" ]] || continue
      homebrew-overlay-base-link-shadowed "${source}" "${base_cellar}" "${user_cellar}" && continue
      relative="var/homebrew/linked/${source##*/}"
      destination="${prefix}/${relative}"
      target="$(readlink "${source}")"
      target="$(homebrew-overlay-rewrite-link-target "${target}" "${base_prefix}" "${prefix}")"
      homebrew-overlay-link-file "${prefix}" "${destination}" "${target}" "${temporary_state}"
    done
  fi

  mv "${temporary_state}" "${state_file}"
  chmod 0600 "${state_file}"
}

homebrew-overlay-sync-unlocked() {
  local prefix="${HOMEBREW_PREFIX}"
  local configured_base base_prefix
  configured_base="${HOMEBREW_OVERLAY_BASE_PREFIX:?HOMEBREW_OVERLAY_BASE_PREFIX is required}"
  base_prefix="$(homebrew-overlay-expand-home "${configured_base}")"

  [[ "${prefix}" != "${base_prefix}" ]] || {
    echo "Error: active user overlay prefix equals its administrator prefix" >&2
    return 1
  }

  homebrew-overlay-sync-cellar "${prefix}/Cellar" "${base_prefix}/Cellar"
  homebrew-overlay-sync-prefix-links "${prefix}" "${base_prefix}"
}

homebrew-overlay-sync() {
  local lock_file="${HOMEBREW_PREFIX}/var/homebrew/locks/overlay-sync.lock"
  homebrew-overlay-safe-mkdir "${HOMEBREW_PREFIX}" "${lock_file%/*}" || return 1

  if command -v flock >/dev/null 2>&1
  then
    (
      flock -x 9
      homebrew-overlay-sync-unlocked
    ) 9>"${lock_file}"
  else
    # `flock` is supplied by util-linux on supported Linux installations. Keep
    # a best-effort fallback so read-only commands still work on minimal hosts.
    homebrew-overlay-sync-unlocked
  fi
}

homebrew-overlay-bootstrap() {
  homebrew-overlay-truthy "${HOMEBREW_OVERLAY:-}" || return 0

  if homebrew-overlay-truthy "${HOMEBREW_OVERLAY_ACTIVE:-}"
  then
    homebrew-overlay-sync
    return 0
  fi

  if homebrew-overlay-prefix-writable "${HOMEBREW_PREFIX}" &&
     ! homebrew-overlay-truthy "${HOMEBREW_OVERLAY_FORCE:-}"
  then
    return 0
  fi

  local base_prefix user_prefix
  base_prefix="$(homebrew-overlay-expand-home "${HOMEBREW_OVERLAY_BASE_PREFIX:-${HOMEBREW_PREFIX}}")"
  user_prefix="$(homebrew-overlay-default-user-prefix)"
  user_prefix="$(homebrew-overlay-initialize-prefix "${base_prefix}" "${HOMEBREW_REPOSITORY}" "${user_prefix}")"

  export HOMEBREW_OVERLAY_ACTIVE=1
  export HOMEBREW_OVERLAY_BASE_PREFIX="${base_prefix}"
  export HOMEBREW_OVERLAY_USER_PREFIX="${user_prefix}"

  exec "${user_prefix}/bin/brew" "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]
then
  case "${1:-}" in
    --sync)
      homebrew-overlay-sync
      ;;
    *)
      echo "Usage: overlay.sh --sync" >&2
      exit 2
      ;;
  esac
fi
