# shellcheck shell=bash

function help_update() {
  cat <<'EOF'
Dockistrate local update workflow

Production deployments should run from release tags (vMAJOR.MINOR.PATCH), not
main. After cloning, run git checkout vX.Y.Z; a detached HEAD at a release tag
is expected for production. Do not use git pull as the production update
workflow.
Dockistrate does not fetch, discover, or apply updates for you.

1. ./dockistrate.sh create-backup
2. git fetch --tags --prune origin
3. ./dockistrate.sh upgrade-preflight --require-backup vX.Y.Z
4. git checkout vX.Y.Z
5. ./dockistrate.sh upgrade-preflight --require-backup
6. Run ./dockistrate.sh check-config if a managed proxy exists
EOF
}

function help_command() {
  case "${1:-}" in
  update)
    help_update
    ;;
  *)
    usage || true
    return 2
    ;;
  esac
}
