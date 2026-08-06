# Homebrew's optional non-service, native-layout user overlay.
#
# The administrator prefix remains a normal read-only Homebrew installation.
# A developer receives a second normal Homebrew prefix (default: ~/.linuxbrew).
# Only package-view links are inherited into the user prefix:
#   Cellar/<formula>, Cellar/<formula>/<version>, opt/<formula>, and
#   var/homebrew/linked/<formula>.
# Executables and other link-tree entries are consumed through the lower prefix
# in `brew shellenv`; recursively projecting bin/lib/include/share is both slow
# and unable to implement directory-union semantics safely.
#
# This file is sourced by bin/brew, which deliberately uses `set -u` without
# `set -e`. Every function must therefore propagate errors explicitly.

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

homebrew-overlay-normalize-absolute() {
  local path="$1"
  [[ "${path}" == /* ]] || return 1
  readlink -m -- "${path}"
}

homebrew-overlay-path-under() {
  local path root
  path="$(homebrew-overlay-normalize-absolute "$1")" || return 1
  root="$(homebrew-overlay-normalize-absolute "$2")" || return 1
  [[ "${path}" == "${root}" || "${path}" == "${root}/"* ]]
}

homebrew-overlay-valid-relative-path() {
  local relative="$1"
  local component
  local -a components=()

  [[ -n "${relative}" && "${relative}" != /* ]] || return 1
  [[ "${relative}" != *$'\n'* && "${relative}" != *$'\r'* ]] || return 1
  IFS=/ read -r -a components <<<"${relative}"
  for component in "${components[@]}"
  do
    [[ -n "${component}" && "${component}" != "." && "${component}" != ".." ]] || return 1
  done
}

homebrew-overlay-formula-name-valid() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9@+._-]*$ ]]
}

homebrew-overlay-base-generation-valid() {
  [[ "$1" =~ ^[0-9a-f]{64}$ ]]
}

homebrew-overlay-generation-file() {
  local prefix="$1"
  printf '%s\n' "${prefix}/var/homebrew/overlay-generation"
}

homebrew-overlay-read-generation() {
  local prefix="$1"
  local generation_file generation
  local -a lines=()

  generation_file="$(homebrew-overlay-generation-file "${prefix}")" || return 1
  [[ -f "${generation_file}" && ! -L "${generation_file}" && -r "${generation_file}" ]] || return 1
  mapfile -t lines <"${generation_file}" || return 1
  ((${#lines[@]} == 1)) || return 1
  generation="${lines[0]}"
  homebrew-overlay-base-generation-valid "${generation}" || return 1
  printf '%s\n' "${generation}"
}

homebrew-overlay-prefix-owned-and-writable() {
  local prefix="$1"
  local owner
  [[ -d "${prefix}" && ! -L "${prefix}" && -w "${prefix}" ]] || return 1
  owner="$(stat -c '%u' -- "${prefix}")" || return 1
  [[ "${owner}" == "$(id -u)" ]]
}

homebrew-overlay-prefix-writable() {
  local prefix="$1"
  [[ -d "${prefix}" && ! -L "${prefix}" && -w "${prefix}" ]] || return 1
  [[ ! -e "${prefix}/Cellar" || ( -d "${prefix}/Cellar" && ! -L "${prefix}/Cellar" && -w "${prefix}/Cellar" ) ]]
}

homebrew-overlay-default-user-prefix() {
  homebrew-overlay-expand-home "${HOMEBREW_OVERLAY_USER_PREFIX:-${HOME}/.linuxbrew}"
}

homebrew-overlay-safe-mkdir() {
  local prefix directory relative component current owner
  local -a components=()

  prefix="$(homebrew-overlay-normalize-absolute "$1")" || return 1
  directory="$(homebrew-overlay-normalize-absolute "$2")" || return 1
  homebrew-overlay-path-under "${directory}" "${prefix}" || return 1
  homebrew-overlay-prefix-owned-and-writable "${prefix}" || return 1

  relative="${directory#"${prefix}"}"
  relative="${relative#/}"
  [[ -z "${relative}" ]] && return 0
  homebrew-overlay-valid-relative-path "${relative}" || return 1

  current="${prefix}"
  IFS=/ read -r -a components <<<"${relative}"
  for component in "${components[@]}"
  do
    current="${current}/${component}"
    if [[ -L "${current}" || ( -e "${current}" && ! -d "${current}" ) ]]
    then
      return 1
    fi
    if [[ ! -d "${current}" ]]
    then
      mkdir -- "${current}" || return 1
    fi
    owner="$(stat -c '%u' -- "${current}")" || return 1
    [[ "${owner}" == "$(id -u)" && -w "${current}" ]] || return 1
  done
}

homebrew-overlay-atomic-write() {
  local destination="$1"
  local mode="$2"
  local temporary="${destination}.tmp.$$.$RANDOM"

  [[ ! -L "${destination}" ]] || return 1
  cat >"${temporary}" || {
    rm -f -- "${temporary}"
    return 1
  }
  chmod "${mode}" "${temporary}" || {
    rm -f -- "${temporary}"
    return 1
  }
  mv -fT -- "${temporary}" "${destination}" || {
    rm -f -- "${temporary}"
    return 1
  }
}

homebrew-overlay-ensure-generation() {
  local prefix="$1"
  local generation_file generation

  prefix="$(homebrew-overlay-normalize-absolute "${prefix}")" || return 1
  generation_file="$(homebrew-overlay-generation-file "${prefix}")" || return 1
  if [[ -e "${generation_file}" || -L "${generation_file}" ]]
  then
    homebrew-overlay-read-generation "${prefix}" >/dev/null || {
      echo "Error: invalid Homebrew overlay generation: ${generation_file}" >&2
      return 1
    }
    return 0
  fi

  homebrew-overlay-prefix-owned-and-writable "${prefix}" || return 1
  homebrew-overlay-safe-mkdir "${prefix}" "${generation_file%/*}" || return 1
  generation="$(homebrew-overlay-structural-view-key "${prefix}")" || return 1
  homebrew-overlay-atomic-write "${generation_file}" 0640 <<<"${generation}" || return 1
}

homebrew-overlay-bump-generation() {
  local prefix="$1"
  local generation_file previous generation

  prefix="$(homebrew-overlay-normalize-absolute "${prefix}")" || return 1
  homebrew-overlay-prefix-owned-and-writable "${prefix}" || return 1
  homebrew-overlay-ensure-generation "${prefix}" || return 1
  generation_file="$(homebrew-overlay-generation-file "${prefix}")" || return 1
  previous="$(homebrew-overlay-read-generation "${prefix}")" || return 1
  generation="$({
    printf '%s\0' "${previous}" "$(date +%s%N)" "$$" "${RANDOM}"
  } | sha256sum | awk '{print $1}')" || return 1
  homebrew-overlay-base-generation-valid "${generation}" || return 1
  homebrew-overlay-atomic-write "${generation_file}" 0640 <<<"${generation}" || return 1
  printf '%s\n' "${generation}"
}

homebrew-overlay-write-prefix-config() {
  local prefix="$1"
  local base_prefix="$2"
  local environment_file="${prefix}/etc/homebrew/overlay.env"

  [[ "${prefix}" != *$'\n'* && "${base_prefix}" != *$'\n'* ]] || return 1
  homebrew-overlay-safe-mkdir "${prefix}" "${environment_file%/*}" || return 1
  if [[ -L "${environment_file}" || ( -e "${environment_file}" && ! -f "${environment_file}" ) ]]
  then
    echo "Error: refusing to replace unsafe Homebrew overlay configuration: ${environment_file}" >&2
    return 1
  fi

  homebrew-overlay-atomic-write "${environment_file}" 0600 <<EOF_ENV
HOMEBREW_OVERLAY=1
HOMEBREW_OVERLAY_ACTIVE=1
HOMEBREW_OVERLAY_BASE_PREFIX=${base_prefix}
HOMEBREW_OVERLAY_USER_PREFIX=${prefix}
HOMEBREW_NO_AUTO_UPDATE=1
EOF_ENV
}

homebrew-overlay-initialize-prefix() {
  local base_prefix repository prefix brew_link brew_target marker existing_base=""
  local directory

  base_prefix="$(homebrew-overlay-normalize-absolute "$1")" || {
    echo "Error: administrator overlay prefix must be absolute" >&2
    return 1
  }
  repository="$(homebrew-overlay-normalize-absolute "$2")" || {
    echo "Error: Homebrew repository must be absolute" >&2
    return 1
  }
  prefix="$(homebrew-overlay-normalize-absolute "$3")" || {
    echo "Error: user overlay prefix must be absolute" >&2
    return 1
  }
  brew_link="${prefix}/bin/brew"
  brew_target="${repository}/bin/brew"
  marker="${prefix}/var/homebrew/overlay/base-prefix"

  [[ -d "${base_prefix}/Cellar" && ! -L "${base_prefix}/Cellar" && -r "${base_prefix}/Cellar" ]] || {
    echo "Error: administrator Cellar is not a readable real directory: ${base_prefix}/Cellar" >&2
    return 1
  }
  [[ -f "${brew_target}" && -x "${brew_target}" ]] || {
    echo "Error: Homebrew launcher is unavailable: ${brew_target}" >&2
    return 1
  }

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
    mkdir -m 0700 -p -- "${prefix}" || return 1
  fi
  homebrew-overlay-prefix-owned-and-writable "${prefix}" || {
    echo "Error: user overlay prefix must be owned and writable by uid $(id -u): ${prefix}" >&2
    return 1
  }

  for directory in \
    bin Caskroom Cellar etc/homebrew Frameworks include lib opt sbin share \
    var/homebrew/linked var/homebrew/locks var/homebrew/overlay/transactions \
    var/homebrew/overlay/transactions/.locks var/homebrew/overlay/sync
  do
    homebrew-overlay-safe-mkdir "${prefix}" "${prefix}/${directory}" || {
      echo "Error: unsafe path inside user overlay prefix: ${prefix}/${directory}" >&2
      return 1
    }
  done

  [[ -d "${prefix}/Cellar" && ! -L "${prefix}/Cellar" ]] || {
    echo "Error: the native user Cellar must be a real directory: ${prefix}/Cellar" >&2
    return 1
  }

  homebrew-overlay-ensure-generation "${prefix}" || {
    echo "Error: could not initialize the user overlay generation: ${prefix}" >&2
    return 1
  }

  if [[ -L "${marker}" || ( -e "${marker}" && ! -f "${marker}" ) ]]
  then
    echo "Error: refusing to use unsafe overlay marker: ${marker}" >&2
    return 1
  elif [[ -r "${marker}" ]]
  then
    IFS= read -r existing_base <"${marker}" || return 1
    if [[ "${existing_base}" != "${base_prefix}" ]]
    then
      echo "Error: ${prefix} already overlays ${existing_base}, not ${base_prefix}" >&2
      return 1
    fi
  else
    homebrew-overlay-atomic-write "${marker}" 0600 <<<"${base_prefix}" || return 1
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
  ln -sfn -- "${brew_target}" "${brew_link}" || return 1

  homebrew-overlay-write-prefix-config "${prefix}" "${base_prefix}" || return 1
  printf '%s\n' "${prefix}"
}

homebrew-overlay-state-file() {
  printf '%s\n' "${HOMEBREW_PREFIX}/var/homebrew/overlay/view.state"
}

homebrew-overlay-record-pair() {
  local file="$1"
  local relative="$2"
  local target="$3"
  homebrew-overlay-valid-relative-path "${relative}" || return 1
  [[ "${target}" == /* && "${target}" != *$'\n'* && "${target}" != *$'\r'* ]] || return 1
  printf '%s\0%s\0' "${relative}" "${target}" >>"${file}"
}

homebrew-overlay-load-state() {
  local file="$1"
  local array_name="$2"
  local relative target
  local -n output_map="${array_name}"
  output_map=()
  [[ -e "${file}" ]] || return 0
  [[ -f "${file}" && ! -L "${file}" ]] || return 1
  while IFS= read -r -d '' relative
  do
    IFS= read -r -d '' target || return 1
    homebrew-overlay-valid-relative-path "${relative}" || return 1
    [[ "${target}" == /* ]] || return 1
    output_map["${relative}"]="${target}"
  done <"${file}"
}

homebrew-overlay-link-matches() {
  local path="$1"
  local target="$2"
  [[ -L "${path}" && "$(readlink "${path}")" == "${target}" ]]
}

homebrew-overlay-rack-has-local-version() {
  local rack="$1"
  local version
  [[ -d "${rack}" && ! -L "${rack}" ]] || return 1
  for version in "${rack}"/*
  do
    [[ -e "${version}" || -L "${version}" ]] || continue
    [[ -L "${version}" ]] || return 0
  done
  return 1
}

homebrew-overlay-build-view() {
  local prefix="$1"
  local base_prefix="$2"
  local output_file="$3"
  local base_cellar="${base_prefix}/Cellar"
  local user_cellar="${prefix}/Cellar"
  local base_rack user_rack name base_version version_name
  local base_opt base_linked

  [[ -d "${base_cellar}" && ! -L "${base_cellar}" ]] || return 1
  [[ -d "${user_cellar}" && ! -L "${user_cellar}" ]] || return 1
  : >"${output_file}" || return 1

  for base_rack in "${base_cellar}"/*
  do
    # Oldname/alias entries in a Cellar are symlinks and are not independent
    # installed racks. Only real administrator racks form the lower package set.
    [[ -d "${base_rack}" && ! -L "${base_rack}" ]] || continue
    name="${base_rack##*/}"
    [[ "${name}" != .* ]] || continue
    homebrew-overlay-formula-name-valid "${name}" || continue
    user_rack="${user_cellar}/${name}"

    if [[ ! -e "${user_rack}" && ! -L "${user_rack}" ]]
    then
      homebrew-overlay-record-pair "${output_file}" "Cellar/${name}" "${base_rack}" || return 1
    elif [[ -L "${user_rack}" ]]
    then
      # Any inherited rack must point exactly at this administrator rack.
      homebrew-overlay-record-pair "${output_file}" "Cellar/${name}" "${base_rack}" || return 1
    elif [[ -d "${user_rack}" ]]
    then
      # A real rack is a native version union. Real children are user kegs;
      # missing administrator versions are read-only symlinks.
      for base_version in "${base_rack}"/*
      do
        [[ -d "${base_version}" && ! -L "${base_version}" ]] || continue
        version_name="${base_version##*/}"
        [[ -e "${user_rack}/${version_name}" || -L "${user_rack}/${version_name}" ]] ||
          homebrew-overlay-record-pair \
            "${output_file}" "Cellar/${name}/${version_name}" "${base_version}" || return 1
      done
    else
      echo "Error: invalid formula rack in user overlay: ${user_rack}" >&2
      return 1
    fi

    # opt and linked-keg records are inherited only while no local realization
    # exists. Executable/library trees are not projected; shellenv provides the
    # lower prefix as a fallback search path.
    if ! homebrew-overlay-rack-has-local-version "${user_rack}"
    then
      base_opt="${base_prefix}/opt/${name}"
      if [[ -L "${base_opt}" && -e "${base_opt}" ]]
      then
        homebrew-overlay-record-pair "${output_file}" "opt/${name}" "${base_opt}" || return 1
      fi
      base_linked="${base_prefix}/var/homebrew/linked/${name}"
      if [[ -L "${base_linked}" && -e "${base_linked}" ]]
      then
        homebrew-overlay-record-pair \
          "${output_file}" "var/homebrew/linked/${name}" "${base_linked}" || return 1
      fi
    fi
  done
}

homebrew-overlay-ensure-parent() {
  local prefix="$1"
  local relative="$2"
  local parent_relative="${relative%/*}"
  local parent="${prefix}/${parent_relative}"

  homebrew-overlay-valid-relative-path "${relative}" || return 1
  if [[ "${parent_relative}" == "${relative}" ]]
  then
    parent="${prefix}"
  fi
  if [[ -d "${parent}" && ! -L "${parent}" && -O "${parent}" && -w "${parent}" ]]
  then
    return 0
  fi
  homebrew-overlay-safe-mkdir "${prefix}" "${parent}"
}

homebrew-overlay-apply-view() {
  local prefix="$1"
  local desired_file="$2"
  local state_file="$3"
  local relative target destination old_target parent index group_index
  local -A old_view=()
  local -A desired_view=()
  local -A add_groups=()
  local -A checked_parents=()
  local -a remove_paths=()
  local -a add_targets=()
  local -a group_targets=()
  local temporary_state="${state_file}.tmp.$$.$RANDOM"

  homebrew-overlay-load-state "${state_file}" old_view || {
    echo "Error: invalid overlay view state: ${state_file}" >&2
    return 1
  }
  homebrew-overlay-load-state "${desired_file}" desired_view || return 1

  # Validate the complete transition before changing any path. Managed links
  # are the only existing entries that may be replaced or removed.
  for relative in "${!desired_view[@]}"
  do
    target="${desired_view[${relative}]}"
    destination="${prefix}/${relative}"
    parent="${destination%/*}"
    if [[ -z "${checked_parents[${parent}]-}" ]]
    then
      homebrew-overlay-ensure-parent "${prefix}" "${relative}" || {
        echo "Error: unsafe parent blocks inherited package view: ${destination}" >&2
        return 1
      }
      checked_parents["${parent}"]=1
    fi
    [[ "${target##*/}" == "${relative##*/}" ]] || {
      echo "Error: inherited package-view target has a mismatched basename: ${target}" >&2
      return 1
    }

    old_target="${old_view[${relative}]-}"
    if [[ -e "${destination}" || -L "${destination}" ]]
    then
      if homebrew-overlay-link-matches "${destination}" "${target}"
      then
        continue
      elif [[ -n "${old_target}" ]] && homebrew-overlay-link-matches "${destination}" "${old_target}"
      then
        remove_paths+=("${destination}")
      else
        echo "Error: user-owned path conflicts with inherited package view: ${destination}" >&2
        return 1
      fi
    fi

    index="${#add_targets[@]}"
    add_targets+=("${target}")
    add_groups["${parent}"]+=" ${index}"
  done

  for relative in "${!old_view[@]}"
  do
    [[ -n "${desired_view[${relative}]-}" ]] && continue
    destination="${prefix}/${relative}"
    if homebrew-overlay-link-matches "${destination}" "${old_view[${relative}]}"
    then
      remove_paths+=("${destination}")
    fi
  done

  if ((${#remove_paths[@]} > 0))
  then
    rm -f -- "${remove_paths[@]}" || return 1
  fi

  # All inherited entries in one parent have matching basenames, allowing GNU
  # ln to create the whole batch in one process instead of spawning twice per
  # package. The durable sync journal makes a partial ln failure recoverable.
  for parent in "${!add_groups[@]}"
  do
    group_targets=()
    for group_index in ${add_groups[${parent}]}
    do
      group_targets+=("${add_targets[${group_index}]}")
    done
    ((${#group_targets[@]} == 0)) ||
      ln -s --target-directory="${parent}" -- "${group_targets[@]}" || return 1
  done

  : >"${temporary_state}" || return 1
  for relative in "${!desired_view[@]}"
  do
    homebrew-overlay-record-pair \
      "${temporary_state}" "${relative}" "${desired_view[${relative}]}" || {
      rm -f -- "${temporary_state}"
      return 1
    }
  done
  chmod 0600 "${temporary_state}" || {
    rm -f -- "${temporary_state}"
    return 1
  }
  mv -fT -- "${temporary_state}" "${state_file}" || return 1
}

homebrew-overlay-structural-view-key() {
  local prefix="$1"
  local cellar="${prefix}/Cellar"
  local opt="${prefix}/opt"
  local linked="${prefix}/var/homebrew/linked"
  local listing

  listing="$(mktemp "${TMPDIR:-/tmp}/homebrew-overlay-key.XXXXXX")" || return 1
  {
    if [[ -d "${cellar}" && ! -L "${cellar}" ]]
    then
      find "${cellar}" -mindepth 1 -maxdepth 2 \
        -printf 'cellar\0%P\0%y\0%T@\0%l\0' || return 1
    else
      printf 'cellar-missing\0'
    fi
    if [[ -d "${opt}" && ! -L "${opt}" ]]
    then
      find "${opt}" -mindepth 1 -maxdepth 1 \
        -printf 'opt\0%P\0%y\0%T@\0%l\0' || return 1
    fi
    if [[ -d "${linked}" && ! -L "${linked}" ]]
    then
      find "${linked}" -mindepth 1 -maxdepth 1 \
        -printf 'linked\0%P\0%y\0%T@\0%l\0' || return 1
    fi
  } >"${listing}" || {
    rm -f -- "${listing}"
    return 1
  }
  sha256sum "${listing}" | awk '{print $1}'
  rm -f -- "${listing}"
}

homebrew-overlay-view-key() {
  local prefix="$1"
  local generation_file

  generation_file="$(homebrew-overlay-generation-file "${prefix}")" || return 1
  if [[ -e "${generation_file}" || -L "${generation_file}" ]]
  then
    homebrew-overlay-read-generation "${prefix}" || {
      echo "Error: invalid Homebrew overlay generation: ${generation_file}" >&2
      return 1
    }
  else
    # Compatibility fallback for an administrator prefix that has not yet been
    # invoked with this fork. The first writable administrator invocation
    # materializes this exact structural key as its explicit generation.
    homebrew-overlay-structural-view-key "${prefix}"
  fi
}

homebrew-overlay-update-base-drift() {
  local prefix="$1"
  local base_key="$2"
  local state_dir="${prefix}/var/homebrew/overlay"
  local state_file="${state_dir}/base-drift.state"
  local warned_file="${state_dir}/base-drift.warned"
  local temporary="${state_file}.tmp.$$.$RANDOM"
  local rack version formula_name version_name marker recorded relative warning_key old_warning=""

  homebrew-overlay-base-generation-valid "${base_key}" || return 1
  homebrew-overlay-safe-mkdir "${prefix}" "${state_dir}" || return 1
  for marker in "${state_file}" "${warned_file}"
  do
    if [[ -L "${marker}" || ( -e "${marker}" && ! -f "${marker}" ) ]]
    then
      echo "Error: unsafe base-generation drift state: ${marker}" >&2
      return 1
    fi
  done
  : >"${temporary}" || return 1
  for rack in "${prefix}/Cellar"/*
  do
    [[ -d "${rack}" && ! -L "${rack}" ]] || continue
    formula_name="${rack##*/}"
    [[ "${formula_name}" != .* ]] || continue
    homebrew-overlay-formula-name-valid "${formula_name}" || continue
    for version in "${rack}"/*
    do
      [[ -d "${version}" && ! -L "${version}" ]] || continue
      version_name="${version##*/}"
      [[ "${version_name}" != .* ]] || continue
      homebrew-overlay-valid-relative-path "${version_name}" || return 1
      [[ "${version_name}" != */* ]] || return 1
      marker="${version}/.brew-overlay-base-generation"
      recorded="missing"
      if [[ -e "${marker}" || -L "${marker}" ]]
      then
        [[ -f "${marker}" && ! -L "${marker}" ]] || {
          rm -f -- "${temporary}"
          echo "Error: unsafe base-generation marker: ${marker}" >&2
          return 1
        }
        IFS= read -r recorded <"${marker}" || {
          rm -f -- "${temporary}"
          return 1
        }
        homebrew-overlay-base-generation-valid "${recorded}" || recorded="invalid"
      fi
      if [[ "${recorded}" != "${base_key}" ]]
      then
        relative="Cellar/${formula_name}/${version_name}"
        homebrew-overlay-valid-relative-path "${relative}" || {
          rm -f -- "${temporary}"
          return 1
        }
        printf '%s\0%s\0' "${relative}" "${recorded}" >>"${temporary}" || {
          rm -f -- "${temporary}"
          return 1
        }
      fi
    done
  done

  chmod 0600 "${temporary}" || {
    rm -f -- "${temporary}"
    return 1
  }
  mv -fT -- "${temporary}" "${state_file}" || return 1

  if [[ -s "${state_file}" ]]
  then
    warning_key="${base_key}:$(sha256sum "${state_file}" | awk '{print $1}')" || return 1
    [[ -f "${warned_file}" ]] && IFS= read -r old_warning <"${warned_file}" || true
    if [[ "${warning_key}" != "${old_warning}" ]]
    then
      echo "Warning: the administrator Homebrew base changed after local formulae were built." >&2
      echo "Run 'brew doctor' and reinstall the reported local formulae before relying on them." >&2
      homebrew-overlay-atomic-write "${warned_file}" 0600 <<<"${warning_key}" || return 1
    fi
  else
    rm -f -- "${state_file}" "${warned_file}" || return 1
  fi
}

homebrew-overlay-sync-transaction-dir() {
  printf '%s\n' "${HOMEBREW_PREFIX}/var/homebrew/overlay/sync"
}

homebrew-overlay-recover-sync() {
  local prefix="$1"
  local transaction_dir state desired state_file
  HOMEBREW_OVERLAY_SYNC_RECOVERED=0
  transaction_dir="$(homebrew-overlay-sync-transaction-dir)"
  state="${transaction_dir}/state"
  desired="${transaction_dir}/desired"
  state_file="$(homebrew-overlay-state-file)"

  [[ -e "${state}" || -e "${desired}" ]] || return 0
  [[ -f "${state}" && ! -L "${state}" && -f "${desired}" && ! -L "${desired}" ]] || {
    echo "Error: incomplete overlay synchronization transaction: ${transaction_dir}" >&2
    return 1
  }
  grep -Fqx 'applying' "${state}" || {
    echo "Error: invalid overlay synchronization transaction state" >&2
    return 1
  }
  homebrew-overlay-apply-view "${prefix}" "${desired}" "${state_file}" || return 1
  rm -f -- "${state}" "${desired}" || return 1
  HOMEBREW_OVERLAY_SYNC_RECOVERED=1
}

homebrew-overlay-remove-version-links() {
  local prefix="$1"
  local version_path="$2"
  local root link resolved listing

  for root in bin sbin include lib share Frameworks opt var/homebrew/linked
  do
    [[ -d "${prefix}/${root}" && ! -L "${prefix}/${root}" ]] || continue
    listing="$(mktemp "${TMPDIR:-/tmp}/homebrew-overlay-links.XXXXXX")" || return 1
    find "${prefix}/${root}" -type l -print0 >"${listing}" || {
      rm -f -- "${listing}"
      return 1
    }
    while IFS= read -r -d '' link
    do
      resolved="$(readlink -f -- "${link}" 2>/dev/null || true)"
      if [[ -n "${resolved}" ]] && homebrew-overlay-path-under "${resolved}" "${version_path}"
      then
        rm -f -- "${link}" || {
          rm -f -- "${listing}"
          return 1
        }
      fi
    done <"${listing}"
    rm -f -- "${listing}" || return 1
  done
}

homebrew-overlay-transaction-marker-id() {
  local marker="$1"
  local marker_id=""

  if [[ -e "${marker}" || -L "${marker}" ]]
  then
    [[ -f "${marker}" && ! -L "${marker}" ]] || {
      echo "Error: unsafe overlay formula transaction marker: ${marker}" >&2
      return 1
    }
    IFS= read -r marker_id <"${marker}" || return 1
    [[ "${marker_id}" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  fi
  printf '%s\n' "${marker_id}"
}

homebrew-overlay-recover-formula-transactions() {
  local prefix="$1"
  local base_prefix="$2"
  local transactions="${prefix}/var/homebrew/overlay/transactions"
  local transaction id formula version state base_generation base_rack local_rack final_version
  local staging_root staging_version replacement_root replacement_rack replacement_version
  local failed_root failed_rack failed_version final_marker replacement_marker failed_marker
  local base_generation_marker recorded_generation final_marker_id replacement_marker_id failed_marker_id
  local owner_lock owner_lock_fd

  HOMEBREW_OVERLAY_FORMULA_RECOVERED=0
  HOMEBREW_OVERLAY_FORMULA_ACTIVE=0
  homebrew-overlay-safe-mkdir "${prefix}" "${transactions}" || return 1
  for transaction in "${transactions}"/*
  do
    [[ -e "${transaction}" || -L "${transaction}" ]] || continue
    if [[ ! -d "${transaction}" || -L "${transaction}" ]]
    then
      echo "Error: unsafe overlay transaction entry: ${transaction}" >&2
      return 1
    fi
    id="${transaction##*/}"
    [[ "${id}" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    owner_lock="${transactions}/.locks/${id}.lock"
    homebrew-overlay-safe-mkdir "${prefix}" "${owner_lock%/*}" || return 1
    if [[ ! -e "${owner_lock}" && ! -L "${owner_lock}" ]]
    then
      (umask 077; set -o noclobber; : >"${owner_lock}") 2>/dev/null || true
    fi
    [[ -f "${owner_lock}" && ! -L "${owner_lock}" && -O "${owner_lock}" ]] || {
      echo "Error: unsafe overlay transaction owner lock: ${owner_lock}" >&2
      return 1
    }
    exec {owner_lock_fd}<>"${owner_lock}" || return 1
    if ! flock -x -n "${owner_lock_fd}"
    then
      if [[ "${id}" != "${HOMEBREW_OVERLAY_OWNER_TRANSACTION_ID:-}" ]]
      then
        HOMEBREW_OVERLAY_FORMULA_ACTIVE=1
      fi
      exec {owner_lock_fd}>&-
      continue
    fi
    HOMEBREW_OVERLAY_FORMULA_RECOVERED=1

    [[ -f "${transaction}/formula" && ! -L "${transaction}/formula" &&
       -f "${transaction}/version" && ! -L "${transaction}/version" &&
       -f "${transaction}/base_generation" && ! -L "${transaction}/base_generation" &&
       -f "${transaction}/state" && ! -L "${transaction}/state" ]] || {
      echo "Error: incomplete overlay formula transaction: ${transaction}" >&2
      return 1
    }
    IFS= read -r formula <"${transaction}/formula" || return 1
    IFS= read -r version <"${transaction}/version" || return 1
    IFS= read -r base_generation <"${transaction}/base_generation" || return 1
    IFS= read -r state <"${transaction}/state" || return 1
    homebrew-overlay-formula-name-valid "${formula}" || return 1
    homebrew-overlay-valid-relative-path "${version}" || return 1
    [[ "${version}" != */* ]] || return 1
    homebrew-overlay-base-generation-valid "${base_generation}" || return 1

    base_rack="${base_prefix}/Cellar/${formula}"
    local_rack="${prefix}/Cellar/${formula}"
    final_version="${local_rack}/${version}"
    staging_root="${prefix}/Cellar/.homebrew-overlay-staging/${id}"
    staging_version="${staging_root}/${formula}/${version}"
    replacement_root="${prefix}/Cellar/.homebrew-overlay-racks/${id}"
    replacement_rack="${replacement_root}/${formula}"
    replacement_version="${replacement_rack}/${version}"
    failed_root="${prefix}/Cellar/.homebrew-overlay-failed/${id}"
    failed_rack="${failed_root}/${formula}"
    failed_version="${failed_rack}/${version}"
    final_marker="${final_version}/.brew-overlay-transaction"
    replacement_marker="${replacement_version}/.brew-overlay-transaction"
    failed_marker="${failed_version}/.brew-overlay-transaction"
    base_generation_marker="${final_version}/.brew-overlay-base-generation"

    final_marker_id="$(homebrew-overlay-transaction-marker-id "${final_marker}")" || return 1
    replacement_marker_id="$(homebrew-overlay-transaction-marker-id "${replacement_marker}")" || return 1
    failed_marker_id="$(homebrew-overlay-transaction-marker-id "${failed_marker}")" || return 1

    case "${state}" in
      staging)
        # The active package view was never changed.
        ;;
      publishing | published | rolling-back)
        if [[ "${final_marker_id}" == "${id}" ]]
        then
          [[ -e "${replacement_rack}" || -L "${replacement_rack}" ]] || {
            echo "Error: transaction ${id} has no previous rack to restore" >&2
            return 1
          }
          homebrew-overlay-remove-version-links "${prefix}" "${final_version}" || return 1
          homebrew-overlay-atomic-write "${transaction}/state" 0600 <<<'recovering-current' || return 1
          homebrew-overlay-safe-mkdir "${prefix}" "${failed_root}" || return 1
          [[ ! -e "${failed_rack}" && ! -L "${failed_rack}" ]] || return 1
          mv -T -- "${local_rack}" "${failed_rack}" || return 1
          homebrew-overlay-atomic-write "${transaction}/state" 0600 <<<'recovering-previous' || return 1
          mv -T -- "${replacement_rack}" "${local_rack}" || return 1
          homebrew-overlay-atomic-write "${transaction}/state" 0600 <<<'recovering-cleanup' || return 1
        elif [[ "${replacement_marker_id}" == "${id}" ]]
        then
          # Publication never exchanged the rack, or rollback already did.
          :
        else
          echo "Error: transaction ${id} does not own either recovery rack" >&2
          return 1
        fi
        ;;
      recovering-current | recovering-previous | recovering-cleanup)
        if [[ "${final_marker_id}" == "${id}" ]]
        then
          homebrew-overlay-remove-version-links "${prefix}" "${final_version}" || return 1
          homebrew-overlay-safe-mkdir "${prefix}" "${failed_root}" || return 1
          [[ ! -e "${failed_rack}" && ! -L "${failed_rack}" ]] || return 1
          mv -T -- "${local_rack}" "${failed_rack}" || return 1
          homebrew-overlay-atomic-write "${transaction}/state" 0600 <<<'recovering-previous' || return 1
          final_marker_id=""
          failed_marker_id="${id}"
        fi
        if [[ "${failed_marker_id}" == "${id}" && ! -e "${local_rack}" && ! -L "${local_rack}" ]]
        then
          [[ -e "${replacement_rack}" || -L "${replacement_rack}" ]] || return 1
          mv -T -- "${replacement_rack}" "${local_rack}" || return 1
          homebrew-overlay-atomic-write "${transaction}/state" 0600 <<<'recovering-cleanup' || return 1
        fi
        if [[ "${failed_marker_id}" != "${id}" ]]
        then
          echo "Error: transaction ${id} has no failed rack to clean" >&2
          return 1
        fi
        ;;
      committing | committed)
        # Commit is the durability boundary: keep the published local rack only
        # when it carries the exact lower-prefix generation from the journal.
        [[ -d "${local_rack}" && ! -L "${local_rack}" &&
           -d "${final_version}" && ! -L "${final_version}" ]] || {
          echo "Error: committed overlay formula rack is missing: ${local_rack}" >&2
          return 1
        }
        [[ -f "${base_generation_marker}" && ! -L "${base_generation_marker}" ]] || {
          echo "Error: committed overlay formula has no safe base-generation marker: ${final_version}" >&2
          return 1
        }
        IFS= read -r recorded_generation <"${base_generation_marker}" || return 1
        if [[ "${recorded_generation}" != "${base_generation}" ]]
        then
          echo "Error: committed overlay formula has the wrong base generation: ${final_version}" >&2
          return 1
        fi
        if [[ -n "${final_marker_id}" && "${final_marker_id}" != "${id}" ]]
        then
          echo "Error: committed overlay formula rack has another transaction marker: ${local_rack}" >&2
          return 1
        elif [[ "${final_marker_id}" == "${id}" ]]
        then
          rm -f -- "${final_marker}" || return 1
        fi
        ;;
      *)
        echo "Error: unknown overlay formula transaction state '${state}'" >&2
        return 1
        ;;
    esac

    # A restored rack must be either the exact administrator rack link or a
    # real inherited-version union. Never invent a replacement for a missing
    # administrator rack during recovery.
    if [[ "${state}" != committing && "${state}" != committed ]]
    then
      [[ -d "${base_rack}" && ! -L "${base_rack}" ]] || {
        echo "Error: administrator rack disappeared during overlay recovery: ${base_rack}" >&2
        return 1
      }
      [[ -e "${local_rack}" || -L "${local_rack}" ]] || {
        ln -s -- "${base_rack}" "${local_rack}" || return 1
      }
    fi

    homebrew-overlay-path-under "${staging_root}" "${prefix}/Cellar/.homebrew-overlay-staging" || return 1
    homebrew-overlay-path-under "${replacement_root}" "${prefix}/Cellar/.homebrew-overlay-racks" || return 1
    homebrew-overlay-path-under "${failed_root}" "${prefix}/Cellar/.homebrew-overlay-failed" || return 1
    rm -rf --one-file-system -- "${staging_root}" "${replacement_root}" "${failed_root}" "${transaction}" || return 1
    rm -f -- "${owner_lock}" || return 1
    exec {owner_lock_fd}>&-
  done
  rmdir "${prefix}/Cellar/.homebrew-overlay-staging" \
        "${prefix}/Cellar/.homebrew-overlay-racks" \
        "${prefix}/Cellar/.homebrew-overlay-failed" 2>/dev/null || true
}

homebrew-overlay-sync-unlocked() {
  local force="${1:-0}"
  local prefix configured_base base_prefix state_dir state_file stamp_file
  local base_key local_key old_base="" old_local=""
  local desired transaction_dir transaction_state transaction_desired temporary_stamp

  prefix="$(homebrew-overlay-normalize-absolute "${HOMEBREW_PREFIX}")" || return 1
  configured_base="${HOMEBREW_OVERLAY_BASE_PREFIX:?HOMEBREW_OVERLAY_BASE_PREFIX is required}"
  base_prefix="$(homebrew-overlay-normalize-absolute "$(homebrew-overlay-expand-home "${configured_base}")")" || return 1
  [[ "${prefix}" != "${base_prefix}" ]] || return 1
  homebrew-overlay-prefix-owned-and-writable "${prefix}" || return 1
  [[ -d "${prefix}/Cellar" && ! -L "${prefix}/Cellar" ]] || {
    echo "Error: user overlay Cellar is not a real directory: ${prefix}/Cellar" >&2
    return 1
  }
  [[ -d "${base_prefix}/Cellar" && ! -L "${base_prefix}/Cellar" && -r "${base_prefix}/Cellar" ]] || {
    echo "Error: administrator Cellar is not a readable real directory: ${base_prefix}/Cellar" >&2
    return 1
  }

  state_dir="${prefix}/var/homebrew/overlay"
  state_file="$(homebrew-overlay-state-file)"
  stamp_file="${state_dir}/view.stamp"
  homebrew-overlay-safe-mkdir "${prefix}" "${state_dir}" || return 1
  homebrew-overlay-recover-formula-transactions "${prefix}" "${base_prefix}" || return 1
  if [[ "${HOMEBREW_OVERLAY_FORMULA_ACTIVE:-0}" -eq 1 ]]
  then
    echo "Error: another Homebrew overlay formula transaction is still active; retry after it finishes" >&2
    return 1
  fi
  homebrew-overlay-recover-sync "${prefix}" || return 1

  if [[ "${HOMEBREW_OVERLAY_FORMULA_RECOVERED:-0}" -eq 1 ]]
  then
    homebrew-overlay-bump-generation "${prefix}" >/dev/null || return 1
    force=1
  fi
  if [[ "${HOMEBREW_OVERLAY_SYNC_RECOVERED:-0}" -eq 1 ]]
  then
    force=1
  fi

  homebrew-overlay-ensure-generation "${prefix}" || return 1

  base_key="$(homebrew-overlay-view-key "${base_prefix}")" || return 1
  local_key="$(homebrew-overlay-view-key "${prefix}")" || return 1
  if [[ "${force}" -eq 0 && -f "${stamp_file}" && ! -L "${stamp_file}" &&
        -f "${state_file}" && ! -L "${state_file}" ]]
  then
    IFS= read -r old_base <"${stamp_file}" || true
    IFS= read -r old_local < <(sed -n '2p' "${stamp_file}") || true
    if [[ "${old_base}" == "${base_key}" && "${old_local}" == "${local_key}" ]]
    then
      return 0
    fi
  fi

  # Drift is a function of the administrator generation and the set of local
  # kegs. Neither can change while both explicit generations match the last
  # committed stamp, so avoid scanning every local keg on read-only commands.
  homebrew-overlay-update-base-drift "${prefix}" "${base_key}" || return 1

  desired="${state_dir}/view.desired.$$.$RANDOM"
  homebrew-overlay-build-view "${prefix}" "${base_prefix}" "${desired}" || {
    rm -f -- "${desired}"
    return 1
  }

  transaction_dir="$(homebrew-overlay-sync-transaction-dir)"
  transaction_state="${transaction_dir}/state"
  transaction_desired="${transaction_dir}/desired"
  homebrew-overlay-safe-mkdir "${prefix}" "${transaction_dir}" || {
    rm -f -- "${desired}"
    return 1
  }
  [[ ! -e "${transaction_state}" && ! -e "${transaction_desired}" ]] || {
    rm -f -- "${desired}"
    echo "Error: overlay synchronization transaction was not recovered" >&2
    return 1
  }
  mv -fT -- "${desired}" "${transaction_desired}" || return 1
  homebrew-overlay-atomic-write "${transaction_state}" 0600 <<<'applying' || return 1
  homebrew-overlay-apply-view "${prefix}" "${transaction_desired}" "${state_file}" || return 1
  rm -f -- "${transaction_state}" "${transaction_desired}" || return 1

  # Synchronization changes only inherited view links, not the local package
  # generation. Store the explicit package generations that produced the view.
  temporary_stamp="${stamp_file}.tmp.$$.$RANDOM"
  printf '%s\n%s\n' "${base_key}" "${local_key}" >"${temporary_stamp}" || return 1
  chmod 0600 "${temporary_stamp}" || {
    rm -f -- "${temporary_stamp}"
    return 1
  }
  mv -fT -- "${temporary_stamp}" "${stamp_file}" || return 1
}

homebrew-overlay-sync() {
  local force=0
  local lock_file
  [[ "${1:-}" == "--force" ]] && force=1
  lock_file="${HOMEBREW_PREFIX}/var/homebrew/locks/overlay-sync.lock"
  homebrew-overlay-safe-mkdir "${HOMEBREW_PREFIX}" "${lock_file%/*}" || return 1

  command -v flock >/dev/null 2>&1 || {
    echo "Error: active Homebrew overlays require flock from util-linux" >&2
    return 1
  }
  (
    flock -x 9 || exit 1
    homebrew-overlay-sync-unlocked "${force}"
  ) 9>"${lock_file}"
}

homebrew-overlay-bootstrap() {
  homebrew-overlay-truthy "${HOMEBREW_OVERLAY:-}" || return 0

  if homebrew-overlay-truthy "${HOMEBREW_OVERLAY_ACTIVE:-}"
  then
    homebrew-overlay-sync || return 1
    return 0
  fi

  if homebrew-overlay-prefix-writable "${HOMEBREW_PREFIX}" &&
     ! homebrew-overlay-truthy "${HOMEBREW_OVERLAY_FORCE:-}"
  then
    # Administrator package mutations use this explicit generation to make
    # developer read-only invocations O(1). Initializing it from the current
    # native package view preserves the pre-marker generation exactly.
    homebrew-overlay-ensure-generation "${HOMEBREW_PREFIX}" || return 1
    return 0
  fi

  local base_prefix user_prefix
  base_prefix="$(homebrew-overlay-normalize-absolute \
    "$(homebrew-overlay-expand-home "${HOMEBREW_OVERLAY_BASE_PREFIX:-${HOMEBREW_PREFIX}}")")" || return 1
  user_prefix="$(homebrew-overlay-default-user-prefix)" || return 1
  user_prefix="$(homebrew-overlay-initialize-prefix "${base_prefix}" "${HOMEBREW_REPOSITORY}" "${user_prefix}")" || return 1

  export HOMEBREW_OVERLAY_ACTIVE=1
  export HOMEBREW_OVERLAY_BASE_PREFIX="${base_prefix}"
  export HOMEBREW_OVERLAY_USER_PREFIX="${user_prefix}"

  exec "${user_prefix}/bin/brew" "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]
then
  case "${1:-}" in
    --sync)
      homebrew-overlay-sync --force
      ;;
    --quick-sync)
      homebrew-overlay-sync
      ;;
    --base-generation)
      base_prefix="$(homebrew-overlay-normalize-absolute         "$(homebrew-overlay-expand-home "${HOMEBREW_OVERLAY_BASE_PREFIX:-}")")" || exit 1
      [[ -d "${base_prefix}/Cellar" && ! -L "${base_prefix}/Cellar" ]] || exit 1
      homebrew-overlay-view-key "${base_prefix}"
      ;;
    --ensure-generation)
      prefix="$(homebrew-overlay-normalize-absolute "${2:-${HOMEBREW_PREFIX:-}}")" || exit 1
      homebrew-overlay-ensure-generation "${prefix}"
      homebrew-overlay-read-generation "${prefix}"
      ;;
    --bump-generation)
      prefix="$(homebrew-overlay-normalize-absolute "${2:-${HOMEBREW_PREFIX:-}}")" || exit 1
      homebrew-overlay-bump-generation "${prefix}"
      ;;
    *)
      echo "Usage: overlay.sh --sync|--quick-sync|--base-generation|--ensure-generation [prefix]|--bump-generation [prefix]" >&2
      exit 2
      ;;
  esac
fi
