#!/bin/bash
# session-registry.sh — read session metadata from config/sessions.json
# source this file; do not exec.
#
# Usage:
#   source lib/session-registry.sh
#   registry_get claude-myproj token_threshold   # => 200000
#   registry_list_all_sessions                     # => one name per line
#   registry_get_json claude-myproj                  # => JSON object
#   registry_slug_to_session myproj                  # => claude-myproj

REGISTRY_FILE="${REGISTRY_FILE:-${LIFEOS_SESSION_REGISTRY:-${LIFEOS_MEMORY_ROOT:-$HOME/lifeos-memory}/config/sessions.json}}"
REGISTRY_CACHE="${REGISTRY_CACHE:-${TMPDIR:-/tmp}/sessions-registry.$(id -u).cache}"

# _registry_refresh — rebuild cache if registry file is newer than cache
_registry_refresh() {
  if [ ! -f "$REGISTRY_FILE" ]; then
    return 1
  fi
  # If cache exists and registry hasn't changed, skip rebuild
  if [ -f "$REGISTRY_CACHE" ] && [ "$REGISTRY_FILE" -ot "$REGISTRY_CACHE" ]; then
    return 0
  fi
  # Rebuild cache: emit one "session.field=value" line per session field
  python3 - "$REGISTRY_FILE" "$REGISTRY_CACHE" <<'PYEOF'
import json, sys

registry_file = sys.argv[1]
cache_file    = sys.argv[2]

with open(registry_file) as f:
    data = json.load(f)

sessions = data.get("sessions", {})
lines = []
for session_name, fields in sessions.items():
    for k, v in fields.items():
        lines.append("{}.{}={}".format(session_name, k, v))

with open(cache_file, "w") as f:
    f.write("\n".join(lines) + "\n")
PYEOF
}

# registry_get <session_name> <field>
# stdout = value; exit 0 = ok, 1 = session not found, 2 = field not found
registry_get() {
  local session="$1"
  local field="$2"

  if [ -z "$session" ] || [ -z "$field" ]; then
    echo "registry_get: requires <session> <field>" >&2
    return 1
  fi

  _registry_refresh || { echo "registry_get: cannot read $REGISTRY_FILE" >&2; return 1; }

  local key="${session}.${field}"
  local line
  line=$(grep "^${key}=" "$REGISTRY_CACHE" 2>/dev/null)
  if [ -z "$line" ]; then
    # Distinguish: does the session exist at all?
    if grep -q "^${session}\." "$REGISTRY_CACHE" 2>/dev/null; then
      return 2   # session found, field missing
    else
      return 1   # session not found
    fi
  fi

  # Print value (everything after first '=')
  echo "${line#*=}"
  return 0
}

# registry_list_all_sessions — stdout: all session names, one per line
registry_list_all_sessions() {
  _registry_refresh || { echo "registry_list_all_sessions: cannot read $REGISTRY_FILE" >&2; return 1; }

  python3 - "$REGISTRY_FILE" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for name in data.get("sessions", {}).keys():
    print(name)
PYEOF
}

# registry_get_json <session_name> — stdout: full JSON object for that session
registry_get_json() {
  local session="$1"
  if [ -z "$session" ]; then
    echo "registry_get_json: requires <session>" >&2
    return 1
  fi

  if [ ! -f "$REGISTRY_FILE" ]; then
    echo "registry_get_json: $REGISTRY_FILE not found" >&2
    return 1
  fi

  python3 - "$REGISTRY_FILE" "$session" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
session = sys.argv[2]
sessions = data.get("sessions", {})
if session not in sessions:
    sys.exit(1)
print(json.dumps(sessions[session], ensure_ascii=False, indent=2))
PYEOF
}

# registry_slug_to_session <slug> — reverse lookup: slug -> session name
# stdout: session name; exit 1 if not found
registry_slug_to_session() {
  local slug="$1"
  if [ -z "$slug" ]; then
    echo "registry_slug_to_session: requires <slug>" >&2
    return 1
  fi

  if [ ! -f "$REGISTRY_FILE" ]; then
    echo "registry_slug_to_session: $REGISTRY_FILE not found" >&2
    return 1
  fi

  python3 - "$REGISTRY_FILE" "$slug" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
target_slug = sys.argv[2]
for name, fields in data.get("sessions", {}).items():
    if fields.get("slug") == target_slug:
        print(name)
        sys.exit(0)
sys.exit(1)
PYEOF
}
