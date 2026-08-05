# Homebrew's optional non-service overlay bootstrap.
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

homebrew-overlay-valid-environment-name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

homebrew-overlay-prefix-writable() {
  local prefix="$1"
  [[ -d "${prefix}" && -w "${prefix}" ]] || return 1
  [[ ! -e "${prefix}/Cellar" || -w "${prefix}/Cellar" ]]
}

homebrew-overlay-default-data-home() {
  if [[ -n "${XDG_DATA_HOME:-}" ]]
  then
    printf '%s\n' "${XDG_DATA_HOME}"
  else
    printf '%s\n' "${HOME}/.local/share"
  fi
}

homebrew-overlay-parent-prefixes() {
  local base_prefix="$1"
  local parents="${HOMEBREW_OVERLAY_PARENT_PREFIXES:-}"

  if [[ -z "${parents}" ]]
  then
    local shared_environment="${HOMEBREW_OVERLAY_SHARED_ENV:-}"
    local shared_environment_dir
    shared_environment_dir="$(homebrew-overlay-expand-home "${HOMEBREW_OVERLAY_SHARED_ENV_DIR:-/develop/homebrew/envs}")"
    if [[ -n "${shared_environment}" ]]
    then
      if ! homebrew-overlay-valid-environment-name "${shared_environment}"
      then
        echo "Error: invalid HOMEBREW_OVERLAY_SHARED_ENV: ${shared_environment}" >&2
        return 1
      fi
      parents="${shared_environment_dir}/${shared_environment}"
    fi
    if [[ -n "${parents}" ]]
    then
      parents="${parents}:${base_prefix}"
    else
      parents="${base_prefix}"
    fi
  fi

  printf '%s\n' "${parents}"
}

homebrew-overlay-write-environment-file() {
  local prefix="$1"
  local base_prefix="$2"
  local environment_name="$3"
  local user_environment_dir="$4"
  local user_package_dir="$5"
  local user_cellar="$6"
  local parent_prefixes="$7"
  local environment_file="${prefix}/etc/homebrew/brew.env"

  mkdir -p "${environment_file%/*}"
  cat >"${environment_file}" <<EOF_ENV
HOMEBREW_OVERLAY=1
HOMEBREW_OVERLAY_ACTIVE=1
HOMEBREW_OVERLAY_BASE_PREFIX=${base_prefix}
HOMEBREW_OVERLAY_ENV=${environment_name}
HOMEBREW_OVERLAY_PARENT_PREFIXES=${parent_prefixes}
HOMEBREW_OVERLAY_USER_ENV_DIR=${user_environment_dir}
HOMEBREW_OVERLAY_USER_PACKAGE_DIR=${user_package_dir}
HOMEBREW_OVERLAY_USER_CELLAR=${user_cellar}
HOMEBREW_NO_AUTO_UPDATE=1
EOF_ENV
  chmod 0600 "${environment_file}"
}

homebrew-overlay-initialize-environment() {
  local base_prefix="$1"
  local repository="$2"
  local environment_name="$3"
  local user_environment_dir="$4"
  local user_package_dir="$5"
  local parent_prefixes="$6"
  local prefix="${user_environment_dir}/${environment_name}"
  local user_cellar="${user_package_dir}/${environment_name}/Cellar"
  local brew_link="${prefix}/bin/brew"
  local brew_target="${repository}/bin/brew"

  mkdir -p \
    "${prefix}/bin" \
    "${prefix}/Caskroom" \
    "${prefix}/etc/homebrew" \
    "${prefix}/opt" \
    "${prefix}/var/homebrew/linked" \
    "${prefix}/var/homebrew/locks" \
    "${user_cellar}"
  chmod 0700 "${prefix}" "${user_environment_dir}" "${user_package_dir}/${environment_name}" 2>/dev/null || true

  if [[ -e "${prefix}/Cellar" && ! -L "${prefix}/Cellar" ]]
  then
    echo "Error: refusing to replace non-symlink overlay Cellar: ${prefix}/Cellar" >&2
    return 1
  fi
  ln -sfn "${user_cellar}" "${prefix}/Cellar"

  if [[ -e "${brew_link}" && ! -L "${brew_link}" ]]
  then
    echo "Error: refusing to replace non-symlink overlay brew: ${brew_link}" >&2
    return 1
  fi
  ln -sfn "${brew_target}" "${brew_link}"

  homebrew-overlay-write-environment-file \
    "${prefix}" \
    "${base_prefix}" \
    "${environment_name}" \
    "${user_environment_dir}" \
    "${user_package_dir}" \
    "${user_cellar}" \
    "${parent_prefixes}"

  printf '%s\n' "${prefix}"
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
    CDPATH='' cd -- "${path%/*}"
    CDPATH='' cd -- "${target_directory}" 2>/dev/null
    printf '%s/%s\n' "$(pwd -P)" "${target_basename}"
  )
}

homebrew-overlay-sync-cellar() {
  local user_cellar="$1"
  local parent_prefixes="$2"
  local rack target parent parent_cellar

  mkdir -p "${user_cellar}"

  # Parent racks are regenerated on every sync. Real directories and unrelated
  # symlinks are user-owned and are never removed here.
  for rack in "${user_cellar}"/*
  do
    [[ -L "${rack}" ]] || continue
    target="$(homebrew-overlay-resolve-link "${rack}" 2>/dev/null || true)"
    [[ -n "${target}" ]] || { rm -f "${rack}"; continue; }

    local inherited=""
    local old_ifs="${IFS}"
    IFS=:
    for parent in ${parent_prefixes}
    do
      parent_cellar="${parent}/Cellar"
      if homebrew-overlay-path-under "${target}" "${parent_cellar}"
      then
        inherited=1
        break
      fi
    done
    IFS="${old_ifs}"
    [[ -n "${inherited}" ]] && rm -f "${rack}"
  done

  # Parent order is highest precedence first. Existing user racks win because
  # they are real directories and therefore already occupy the destination.
  local old_ifs="${IFS}"
  IFS=:
  for parent in ${parent_prefixes}
  do
    parent_cellar="${parent}/Cellar"
    [[ -d "${parent_cellar}" ]] || continue
    for rack in "${parent_cellar}"/*
    do
      [[ -d "${rack}" ]] || continue
      [[ "${rack##*/}" == .* ]] && continue
      [[ -e "${user_cellar}/${rack##*/}" || -L "${user_cellar}/${rack##*/}" ]] || \
        ln -s "${rack}" "${user_cellar}/${rack##*/}"
    done
  done
  IFS="${old_ifs}"
}

homebrew-overlay-remove-recorded-links() {
  local prefix="$1"
  local manifest="$2"
  local path target

  [[ -r "${manifest}" ]] || return 0
  while IFS=$'\t' read -r path target
  do
    [[ -n "${path}" && -n "${target}" ]] || continue
    homebrew-overlay-path-under "${path}" "${prefix}" || continue
    if [[ -L "${path}" && "$(readlink "${path}")" == "${target}" ]]
    then
      rm -f "${path}"
    fi
  done <"${manifest}"
}

homebrew-overlay-record-link() {
  local manifest="$1"
  local path="$2"
  local target="$3"
  printf '%s\t%s\n' "${path}" "${target}" >>"${manifest}"
}

homebrew-overlay-link-file() {
  local prefix="$1"
  local source="$2"
  local destination="$3"
  local manifest="$4"

  [[ -e "${destination}" || -L "${destination}" ]] && return 0
  mkdir -p "${destination%/*}"
  ln -s "${source}" "${destination}"
  homebrew-overlay-record-link "${manifest}" "${destination}" "${source}"
}

homebrew-overlay-sync-prefix-links() {
  local prefix="$1"
  local parent_prefixes="$2"
  local manifest="${prefix}/var/homebrew/overlay-links.tsv"
  local temporary_manifest="${manifest}.tmp.$$"
  local parent root source relative destination target_real rack version link_target

  mkdir -p "${manifest%/*}"
  homebrew-overlay-remove-recorded-links "${prefix}" "${manifest}"
  : >"${temporary_manifest}"

  local old_ifs="${IFS}"
  IFS=:
  for parent in ${parent_prefixes}
  do
    [[ -d "${parent}" ]] || continue

    for root in bin sbin include lib share Frameworks
    do
      [[ -d "${parent}/${root}" ]] || continue
      while IFS= read -r -d '' source
      do
        relative="${source#"${parent}/"}"
        [[ "${relative}" == "bin/brew" ]] && continue
        destination="${prefix}/${relative}"
        if [[ -d "${source}" && ! -L "${source}" ]]
        then
          [[ -e "${destination}" || -L "${destination}" ]] || mkdir -p "${destination}"
        else
          homebrew-overlay-link-file "${prefix}" "${source}" "${destination}" "${temporary_manifest}"
        fi
      done < <(find "${parent}/${root}" -mindepth 1 -print0)
    done

    if [[ -d "${parent}/opt" ]]
    then
      for source in "${parent}/opt"/*
      do
        [[ -L "${source}" && -e "${source}" ]] || continue
        target_real="$(readlink -f "${source}")" || continue
        rack="${target_real%/*}"
        version="${target_real##*/}"
        rack="${rack##*/}"
        [[ -d "${prefix}/Cellar/${rack}/${version}" ]] || continue
        destination="${prefix}/opt/${source##*/}"
        [[ -e "${destination}" || -L "${destination}" ]] && continue
        link_target="../Cellar/${rack}/${version}"
        ln -s "${link_target}" "${destination}"
        homebrew-overlay-record-link "${temporary_manifest}" "${destination}" "${link_target}"
      done
    fi

    if [[ -d "${parent}/var/homebrew/linked" ]]
    then
      for source in "${parent}/var/homebrew/linked"/*
      do
        [[ -L "${source}" && -e "${source}" ]] || continue
        target_real="$(readlink -f "${source}")" || continue
        rack="${target_real%/*}"
        version="${target_real##*/}"
        rack="${rack##*/}"
        [[ -d "${prefix}/Cellar/${rack}/${version}" ]] || continue
        destination="${prefix}/var/homebrew/linked/${source##*/}"
        [[ -e "${destination}" || -L "${destination}" ]] && continue
        link_target="${prefix}/Cellar/${rack}/${version}"
        ln -s "${link_target}" "${destination}"
        homebrew-overlay-record-link "${temporary_manifest}" "${destination}" "${link_target}"
      done
    fi
  done
  IFS="${old_ifs}"

  mv "${temporary_manifest}" "${manifest}"
  chmod 0600 "${manifest}"
}

homebrew-overlay-sync-unlocked() {
  local prefix="${HOMEBREW_PREFIX}"
  local user_cellar
  local parent_prefixes
  user_cellar="$(homebrew-overlay-expand-home "${HOMEBREW_OVERLAY_USER_CELLAR:?HOMEBREW_OVERLAY_USER_CELLAR is required}")"
  parent_prefixes="${HOMEBREW_OVERLAY_PARENT_PREFIXES:?HOMEBREW_OVERLAY_PARENT_PREFIXES is required}"

  if [[ ! -L "${prefix}/Cellar" || "$(readlink "${prefix}/Cellar")" != "${user_cellar}" ]]
  then
    echo "Error: overlay Cellar does not point to its package store: ${prefix}/Cellar" >&2
    return 1
  fi

  homebrew-overlay-sync-cellar "${user_cellar}" "${parent_prefixes}"
  homebrew-overlay-sync-prefix-links "${prefix}" "${parent_prefixes}"
}

homebrew-overlay-sync() {
  local lock_file="${HOMEBREW_PREFIX}/var/homebrew/locks/overlay-sync.lock"
  mkdir -p "${lock_file%/*}"

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

  local environment_name="${HOMEBREW_OVERLAY_ENV:-default}"
  if ! homebrew-overlay-valid-environment-name "${environment_name}"
  then
    echo "Error: invalid HOMEBREW_OVERLAY_ENV: ${environment_name}" >&2
    return 1
  fi

  local data_home
  local base_prefix
  local user_environment_dir
  local user_package_dir
  local parent_prefixes
  local prefix
  data_home="$(homebrew-overlay-default-data-home)"
  base_prefix="$(homebrew-overlay-expand-home "${HOMEBREW_OVERLAY_BASE_PREFIX:-${HOMEBREW_PREFIX}}")"
  user_environment_dir="$(homebrew-overlay-expand-home "${HOMEBREW_OVERLAY_USER_ENV_DIR:-${data_home}/homebrew/envs}")"
  user_package_dir="$(homebrew-overlay-expand-home "${HOMEBREW_OVERLAY_USER_PACKAGE_DIR:-${data_home}/homebrew/pkgs}")"
  parent_prefixes="$(homebrew-overlay-parent-prefixes "${base_prefix}")"
  prefix="$(homebrew-overlay-initialize-environment \
    "${base_prefix}" \
    "${HOMEBREW_REPOSITORY}" \
    "${environment_name}" \
    "${user_environment_dir}" \
    "${user_package_dir}" \
    "${parent_prefixes}")"

  export HOMEBREW_OVERLAY_ACTIVE=1
  export HOMEBREW_OVERLAY_BASE_PREFIX="${base_prefix}"
  export HOMEBREW_OVERLAY_PARENT_PREFIXES="${parent_prefixes}"
  export HOMEBREW_OVERLAY_USER_ENV_DIR="${user_environment_dir}"
  export HOMEBREW_OVERLAY_USER_PACKAGE_DIR="${user_package_dir}"
  export HOMEBREW_OVERLAY_USER_CELLAR="${user_package_dir}/${environment_name}/Cellar"

  exec "${prefix}/bin/brew" "$@"
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
