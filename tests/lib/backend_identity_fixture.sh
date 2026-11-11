# shellcheck shell=bash

# Stateful lifecycle mocks use this renderer with labels saved at creation.
# The expected inspect predicate is checked against the fixture's real labels;
# neither the requested name nor the template creates ownership evidence.
function backend_fixture_snapshot() {
  local template="$1" id="$2" status="$3" labels_file="$4" network="${5:-dockistrate-net}" ip="${6:-172.30.0.99}"
  local image="${7:-nginx:alpine}"
  local key="" pair="" value="" escaped="" proof=verified code=0 octal="" char="" escaped_char=""
  [[ "$template" == *"(eq .Id \"$id\")"* ]] || proof=unverified
  for key in com.dockistrate.managed com.dockistrate.role com.dockistrate.state-dir com.dockistrate.backend-domain com.dockistrate.backend-launch; do
    value=""
    if [ -f "$labels_file" ]; then
      while IFS= read -r pair; do
        [ "${pair%%=*}" != "$key" ] || value="${pair#*=}"
      done <"$labels_file"
    fi
    escaped="${value//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    for ((code = 1; code < 32; code++)); do
      printf -v octal '%03o' "$code"
      printf -v char '%b' "\\$octal"
      printf -v escaped_char '\\x%02x' "$code"
      escaped="${escaped//$char/$escaped_char}"
    done
    [ -n "$value" ] || proof=unverified
    [[ "$template" == *"(eq (index .Config.Labels \"$key\") \"$escaped\")"* ]] || proof=unverified
  done
  printf '%s\n%s\n%s\n%s\nsha256:%064d\n%s|%s\n' "$proof" "$id" "$status" "$image" 9 "$network" "$ip"
}

function backend_fixture_seed_labels() {
  local file="$1" token="$2" domain="$3" state_dir="$4"
  # Match production labels when TMPDIR contains macOS /var aliases, redundant
  # separators, or a symlink. Keep the actual label comparison literal.
  state_dir="$(_realpath_portable "$state_dir" && printf '.')" || return 1
  state_dir="${state_dir%.}"
  printf '%s\n' 'com.dockistrate.managed=true' 'com.dockistrate.role=backend' \
    "com.dockistrate.state-dir=$state_dir" "com.dockistrate.backend-domain=$domain" \
    "com.dockistrate.backend-launch=$token" >"$file"
}
