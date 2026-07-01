# shellcheck shell=bash
function container_exists() {
  local cname="${1:-}"
  docker ps -a --filter "name=^/${cname}$" --format '{{.Names}}' | grep -Fx -- "$cname" &>/dev/null
  return $?
}

# Remove a container and clean up any anonymous volumes attached to it.
function remove_container_and_anonymous_volumes() {
  local cname="${1:-}"
  docker rm -f -v "$cname"
}

# Remove a container without deleting its anonymous volumes.
function remove_container_preserving_volumes() {
  local cname="${1:-}"
  docker rm -f "$cname"
}

# Return the container state string (running, exited, etc.) or empty if missing
function container_status() {
  local cname="${1:-}"
  docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null || true
}

# Check if a container is currently running
function container_running() {
  local cname="${1:-}"
  [ "$(container_status "$cname")" = "running" ]
}

# Return sorted list of host port bindings published by the container as "port/proto".
function container_published_port_bindings() {
  local cname="${1:-}"
  docker port "$cname" 2>/dev/null | awk '
    {
      split($1, mapped, "/")
      proto = mapped[2]
      host = $3
      sub(/^.*:/, "", host)
      if (host ~ /^[0-9]+$/ && (proto == "tcp" || proto == "udp")) {
        print host "/" proto
      }
    }
  ' | sort -u
}

# Return sorted list of host ports published by the container.
function container_published_ports() {
  local cname="${1:-}"
  container_published_port_bindings "$cname" | cut -d'/' -f1 | sort -u
}

function ensure_network_exists() {
  local net="${1:-}"
  if ! docker network ls --format '{{.Name}}' | grep -Fx -- "$net" >/dev/null; then
    docker network create "$net" >/dev/null
  fi
}
