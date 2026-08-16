#!/bin/bash
set -euo pipefail
umask 077

repository="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
repository="$(cd "${repository}" && pwd -P)"

output="$(env \
  HOMEBREW_NO_AUTO_UPDATE=1 \
  HOMEBREW_SKIP_INITIAL_GEM_INSTALL=1 \
  "${repository}/bin/brew" ruby -e 'require "fiddle"; print Fiddle::VERSION')"

[[ "${output}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
printf 'overlay disabled-gems runtime boot test: PASS\n'
