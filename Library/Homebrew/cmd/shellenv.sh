# Documentation defined in Library/Homebrew/cmd/shellenv.rb

# HOMEBREW_CELLAR and HOMEBREW_PREFIX are set by extend/ENV/super.rb
# HOMEBREW_REPOSITORY is set by bin/brew
# Leading colon in MANPATH prepends default man dirs to search path in Linux and macOS.
# Trailing colon in INFOPATH appends the default info dirs to the search path.
# Please do not submit PRs to remove it!
# shellcheck disable=SC2154
homebrew-shellenv() {
  local PATH_HELPER_ROOT="${PATH_HELPER_ROOT:-}"
  local HOMEBREW_PATH="${HOMEBREW_PATH:-${PATH:-}}"
  local HOMEBREW_SHELLENV_PATH_PREFIX="${HOMEBREW_PREFIX}/bin:${HOMEBREW_PREFIX}/sbin"
  local HOMEBREW_SHELLENV_INFO_PREFIX="${HOMEBREW_PREFIX}/share/info"
  local HOMEBREW_SHELLENV_BASE_PREFIX=""
  if [[ -n "${HOMEBREW_OVERLAY_ACTIVE:-}" && -n "${HOMEBREW_OVERLAY_BASE_PREFIX:-}" &&
        "${HOMEBREW_OVERLAY_BASE_PREFIX%/}" != "${HOMEBREW_PREFIX}" ]]
  then
    HOMEBREW_SHELLENV_BASE_PREFIX="${HOMEBREW_OVERLAY_BASE_PREFIX%/}"
    HOMEBREW_SHELLENV_PATH_PREFIX+=":${HOMEBREW_SHELLENV_BASE_PREFIX}/bin:${HOMEBREW_SHELLENV_BASE_PREFIX}/sbin"
    HOMEBREW_SHELLENV_INFO_PREFIX+=":${HOMEBREW_SHELLENV_BASE_PREFIX}/share/info"
  fi

  if [[ "${HOMEBREW_PATH}" == "${HOMEBREW_SHELLENV_PATH_PREFIX}" ||
        "${HOMEBREW_PATH}" == "${HOMEBREW_SHELLENV_PATH_PREFIX}:"* ]]
  then
    return
  fi

  # Use specified shell name parameter, if available.
  HOMEBREW_SHELL_NAME="${1:-}"

  # Use the parent process name, if possible.
  # This is known to fail under some sandboxes.
  if [[ -z "${HOMEBREW_SHELL_NAME}" ]]
  then
    HOMEBREW_SHELL_NAME="$(/bin/ps -p "${PPID}" -c -o comm= 2>/dev/null)"
  fi

  # Fall back to the (login) shell name from the environment.
  if [[ -z "${HOMEBREW_SHELL_NAME}" ]]
  then
    HOMEBREW_SHELL_NAME="${SHELL##*/}"
  fi

  if [[ -n "${HOMEBREW_MACOS}" ]] &&
     [[ "${HOMEBREW_MACOS_VERSION_NUMERIC}" -ge "140000" ]] &&
     [[ -x /usr/libexec/path_helper ]]
  then
    HOMEBREW_PATHS_FILE="${HOMEBREW_PREFIX}/etc/paths"

    if [[ ! -f "${HOMEBREW_PATHS_FILE}" ]]
    then
      printf '%s/bin\n%s/sbin\n' "${HOMEBREW_PREFIX}" "${HOMEBREW_PREFIX}" 2>/dev/null >"${HOMEBREW_PATHS_FILE}"
    fi

    if [[ -r "${HOMEBREW_PATHS_FILE}" ]]
    then
      PATH_HELPER_ROOT="${HOMEBREW_PREFIX}"
    fi
  fi

  case "${HOMEBREW_SHELL_NAME}" in
    fish | -fish)
      echo "set --global --export HOMEBREW_PREFIX \"${HOMEBREW_PREFIX}\";"
      echo "set --global --export HOMEBREW_CELLAR \"${HOMEBREW_CELLAR}\";"
      echo "set --global --export HOMEBREW_REPOSITORY \"${HOMEBREW_REPOSITORY}\";"
      if [[ -n "${HOMEBREW_SHELLENV_BASE_PREFIX}" ]]
      then
        echo "set --global --export HOMEBREW_OVERLAY_ACTIVE 1;"
        echo "set --global --export HOMEBREW_OVERLAY_BASE_PREFIX \"${HOMEBREW_SHELLENV_BASE_PREFIX}\";"
        echo "fish_add_path --global --move --path \"${HOMEBREW_SHELLENV_BASE_PREFIX}/bin\" \"${HOMEBREW_SHELLENV_BASE_PREFIX}/sbin\";"
      fi
      echo "fish_add_path --global --move --path \"${HOMEBREW_PREFIX}/bin\" \"${HOMEBREW_PREFIX}/sbin\";"
      echo "if test -n \"\$MANPATH[1]\"; set --global --export MANPATH '' \$MANPATH; end;"
      echo "if not set --query INFOPATH; set INFOPATH ''; end;"
      if [[ -n "${HOMEBREW_SHELLENV_BASE_PREFIX}" ]]
      then
        echo "if not contains \"${HOMEBREW_SHELLENV_BASE_PREFIX}/share/info\" \$INFOPATH; set --global --prepend INFOPATH \"${HOMEBREW_SHELLENV_BASE_PREFIX}/share/info\"; end;"
      fi
      echo "if not contains \"${HOMEBREW_PREFIX}/share/info\" \$INFOPATH; set --global --prepend INFOPATH \"${HOMEBREW_PREFIX}/share/info\"; end;"
      ;;
    csh | -csh | tcsh | -tcsh)
      echo "setenv HOMEBREW_PREFIX ${HOMEBREW_PREFIX};"
      echo "setenv HOMEBREW_CELLAR ${HOMEBREW_CELLAR};"
      echo "setenv HOMEBREW_REPOSITORY ${HOMEBREW_REPOSITORY};"
      if [[ -n "${HOMEBREW_SHELLENV_BASE_PREFIX}" ]]
      then
        echo "setenv HOMEBREW_OVERLAY_ACTIVE 1;"
        echo "setenv HOMEBREW_OVERLAY_BASE_PREFIX ${HOMEBREW_SHELLENV_BASE_PREFIX};"
      fi
      if [[ -n "${PATH_HELPER_ROOT}" ]]
      then
        echo "eval \`/usr/bin/env PATH_HELPER_ROOT=\"${PATH_HELPER_ROOT}\" /usr/libexec/path_helper -c\`;"
      else
        echo "setenv PATH ${HOMEBREW_SHELLENV_PATH_PREFIX}:\$PATH;"
      fi
      echo "test \${?MANPATH} -eq 1 && setenv MANPATH :\${MANPATH};"
      echo "setenv INFOPATH ${HOMEBREW_SHELLENV_INFO_PREFIX}\`test \${?INFOPATH} -eq 1 && echo :\${INFOPATH}\`;"
      ;;
    pwsh | -pwsh | pwsh-preview | -pwsh-preview)
      echo "[System.Environment]::SetEnvironmentVariable('HOMEBREW_PREFIX','${HOMEBREW_PREFIX}',[System.EnvironmentVariableTarget]::Process)"
      echo "[System.Environment]::SetEnvironmentVariable('HOMEBREW_CELLAR','${HOMEBREW_CELLAR}',[System.EnvironmentVariableTarget]::Process)"
      echo "[System.Environment]::SetEnvironmentVariable('HOMEBREW_REPOSITORY','${HOMEBREW_REPOSITORY}',[System.EnvironmentVariableTarget]::Process)"
      if [[ -n "${HOMEBREW_SHELLENV_BASE_PREFIX}" ]]
      then
        echo "[System.Environment]::SetEnvironmentVariable('HOMEBREW_OVERLAY_ACTIVE','1',[System.EnvironmentVariableTarget]::Process)"
        echo "[System.Environment]::SetEnvironmentVariable('HOMEBREW_OVERLAY_BASE_PREFIX','${HOMEBREW_SHELLENV_BASE_PREFIX}',[System.EnvironmentVariableTarget]::Process)"
      fi
      echo "[System.Environment]::SetEnvironmentVariable('PATH',\$('${HOMEBREW_SHELLENV_PATH_PREFIX}:'+\$ENV:PATH),[System.EnvironmentVariableTarget]::Process)"
      echo "[System.Environment]::SetEnvironmentVariable('MANPATH',\$('${HOMEBREW_PREFIX}/share/man'+\$(if(\${ENV:MANPATH}){':'+\${ENV:MANPATH}})+':'),[System.EnvironmentVariableTarget]::Process)"
      echo "[System.Environment]::SetEnvironmentVariable('INFOPATH',\$('${HOMEBREW_SHELLENV_INFO_PREFIX}'+\$(if(\${ENV:INFOPATH}){':'+\${ENV:INFOPATH}})),[System.EnvironmentVariableTarget]::Process)"
      ;;
    *)
      echo "export HOMEBREW_PREFIX=\"${HOMEBREW_PREFIX}\";"
      echo "export HOMEBREW_CELLAR=\"${HOMEBREW_CELLAR}\";"
      echo "export HOMEBREW_REPOSITORY=\"${HOMEBREW_REPOSITORY}\";"
      if [[ -n "${HOMEBREW_SHELLENV_BASE_PREFIX}" ]]
      then
        echo "export HOMEBREW_OVERLAY_ACTIVE=1;"
        echo "export HOMEBREW_OVERLAY_BASE_PREFIX=\"${HOMEBREW_SHELLENV_BASE_PREFIX}\";"
      fi
      if [[ "${HOMEBREW_SHELL_NAME}" == "zsh" ]] || [[ "${HOMEBREW_SHELL_NAME}" == "-zsh" ]]
      then
        echo "fpath[1,0]=\"${HOMEBREW_PREFIX}/share/zsh/site-functions\";"
        if [[ -n "${HOMEBREW_SHELLENV_BASE_PREFIX}" ]]
        then
          echo "fpath[2,0]=\"${HOMEBREW_SHELLENV_BASE_PREFIX}/share/zsh/site-functions\";"
        fi
        echo "export FPATH;"
      fi
      if [[ -n "${PATH_HELPER_ROOT}" ]]
      then
        echo "eval \"\$(/usr/bin/env PATH_HELPER_ROOT=\"${PATH_HELPER_ROOT}\" /usr/libexec/path_helper -s)\""
      else
        echo "export PATH=\"${HOMEBREW_SHELLENV_PATH_PREFIX}\${PATH+:\$PATH}\";"
      fi
      echo "[ -z \"\${MANPATH-}\" ] || export MANPATH=\":\${MANPATH#:}\";"
      echo "export INFOPATH=\"${HOMEBREW_SHELLENV_INFO_PREFIX}:\${INFOPATH:-}\";"
      ;;
  esac
}
