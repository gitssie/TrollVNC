#!/bin/bash
# Dopamine 3 production build. Source from the repository root.
if [ -z "${THEOS:-}" ]; then
  if [ -d "$HOME/theos" ]; then
    export THEOS="$HOME/theos"
  elif [ -n "${GITHUB_WORKSPACE:-}" ] && [ -d "$GITHUB_WORKSPACE/theos" ]; then
    export THEOS="$GITHUB_WORKSPACE/theos"
  else
    export THEOS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../theos" && pwd -P)"
  fi
fi
export THEOS_PACKAGE_SCHEME=rootless
export THEOS_DEVICE_SIMULATOR=
export THEBOOTSTRAP=
