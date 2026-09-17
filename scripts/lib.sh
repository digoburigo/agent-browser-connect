#!/usr/bin/env bash
# Shared validation, endpoint, and lifecycle helpers for connect.sh and cleanup.sh.

ab_is_uint() {
  local value="${1:-}"
  case "$value" in
    ''|*[!0-9]*) return 1 ;;
  esac
}

ab_validate_session() {
  local value="${1:-}"
  [ -n "$value" ] || return 1
  [ "${#value}" -le 64 ] || return 1
  case "$value" in
    [A-Za-z0-9]*) ;;
    *) return 1 ;;
  esac
  case "$value" in
    *[!A-Za-z0-9_-]*) return 1 ;;
  esac
}

ab_sanitize_component() {
  local value="${1:-}"
  local sanitized
  sanitized="$(printf '%s' "$value" \
    | LC_ALL=C tr -c 'A-Za-z0-9_-' '-' \
    | LC_ALL=C tr 'A-Z' 'a-z' \
    | sed 's/[-_][-_]*/-/g; s/^-*//; s/-*$//')"
  [ -n "$sanitized" ] || sanitized="browser"
  printf '%.28s' "$sanitized"
}

ab_validate_slot() {
  local value="${1:-}"
  [ -n "$value" ] || return 1
  [ "${#value}" -le 28 ] || return 1
  case "$value" in
    [A-Za-z0-9]*) ;;
    *) return 1 ;;
  esac
  case "$value" in
    *[!A-Za-z0-9_-]*) return 1 ;;
  esac
}

ab_hash_value() {
  local value="$1"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$value" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$value" | sha256sum | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    printf '%s' "$value" | openssl dgst -sha256 | awk '{print $NF}'
  else
    return 1
  fi
}

ab_owner_key() {
  local owner_id="$1"
  local slot="$2"
  local port="$3"
  ab_hash_value "$owner_id|$slot|$port"
}

ab_session_lock_key() {
  local session="$1"
  ab_validate_session "$session" || return 1
  ab_hash_value "session:$session"
}

ab_meta_value() {
  local file="$1"
  local key="$2"
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  case "$key" in
    ''|*[!A-Za-z0-9_]*) return 1 ;;
  esac
  awk -v key="$key" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' "$file"
}

ab_validate_meta_value() {
  local value="$1"
  case "$value" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
}

ab_set_meta_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  case "$key" in
    ''|*[!A-Za-z0-9_]*) return 1 ;;
  esac
  ab_validate_meta_value "$value" || return 1
  tmp="$file.tmp.$$"
  [ ! -e "$tmp" ] && [ ! -L "$tmp" ] || return 1
  awk -v key="$key" -v value="$value" '
    BEGIN { replaced = 0 }
    index($0, key "=") == 1 {
      if (!replaced) print key "=" value
      replaced = 1
      next
    }
    { print }
    END { if (!replaced) print key "=" value }
  ' "$file" > "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  chmod 600 "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv -f "$tmp" "$file"
}

# Append one line to the session's events.log. Records every operation that can
# move Chrome's visible tab (fresh attach, tab new, drift restore) so a shared
# browser can be audited after the fact. Best effort: never fails the caller.
ab_log_event() {
  local dir="$1"
  local event="$2"
  shift 2
  local details="$*"
  local file="$dir/events.log"
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  [ ! -L "$file" ] || return 0
  case "$event$details" in
    *$'\n'*|*$'\r'*) return 0 ;;
  esac
  printf '%s pid=%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "$event" "$details" >> "$file" 2>/dev/null || return 0
  chmod 600 "$file" 2>/dev/null || true
}

ab_lock_root() {
  printf '%s/.locks' "${1%/}"
}

ab_path_age_seconds() {
  local path="$1"
  local modified=""
  local now

  modified="$(stat -f '%m' "$path" 2>/dev/null || true)"
  if ! ab_is_uint "$modified"; then
    modified="$(stat -c '%Y' "$path" 2>/dev/null || true)"
  fi
  ab_is_uint "$modified" || {
    printf '%s\n' "0"
    return 0
  }

  now="$(date +%s)"
  if ! ab_is_uint "$now" || [ "$now" -lt "$modified" ]; then
    printf '%s\n' "0"
    return 0
  fi
  printf '%s\n' "$((now - modified))"
}

ab_lock_is_stale() {
  local lock_path="$1"
  local stale_after="${AB_LOCK_UNINITIALIZED_STALE_SECONDS:-5}"
  local holder age

  [ -d "$lock_path" ] && [ ! -L "$lock_path" ] && [ -O "$lock_path" ] || return 1
  holder="$(sed -n '1p' "$lock_path/pid" 2>/dev/null || true)"
  if ab_is_uint "$holder"; then
    ! kill -0 "$holder" 2>/dev/null
    return
  fi

  ab_is_uint "$stale_after" || stale_after=5
  age="$(ab_path_age_seconds "$lock_path")"
  [ "$age" -ge "$stale_after" ]
}

ab_acquire_lock() {
  local root="$1"
  local owner_key="$2"
  local attempts="${AB_LOCK_ATTEMPTS:-300}"
  local delay="${AB_LOCK_DELAY_SECONDS:-0.1}"
  local lock_root lock_path reaper_path stale_path attempt

  case "$attempts" in
    ''|*[!0-9]*) return 2 ;;
  esac
  case "$owner_key" in
    ''|*[!A-Fa-f0-9]*) return 2 ;;
  esac

  lock_root="$(ab_lock_root "$root")"
  ab_prepare_private_dir "$lock_root" || return 2
  lock_path="$lock_root/$owner_key.lock"
  reaper_path="$lock_path.reap"

  for ((attempt = 0; attempt <= attempts; attempt += 1)); do
    if [ ! -d "$reaper_path" ] && (umask 077; mkdir "$lock_path") 2>/dev/null; then
      if [ -d "$reaper_path" ]; then
        rmdir "$lock_path" 2>/dev/null || true
      else
        AB_LOCK_TOKEN="$$-$(ab_hash_value "$owner_key|$$|$attempt" | cut -c1-16)"
        if printf '%s\n' "$$" > "$lock_path/pid" \
          && printf '%s\n' "$AB_LOCK_TOKEN" > "$lock_path/token" \
          && chmod 600 "$lock_path/pid" "$lock_path/token"; then
          AB_HELD_LOCK="$lock_path"
          export AB_HELD_LOCK AB_LOCK_TOKEN
          return 0
        fi
        rm -rf "$lock_path"
        unset AB_LOCK_TOKEN
        return 2
      fi
    fi

    if ab_lock_is_stale "$lock_path" && (umask 077; mkdir "$reaper_path") 2>/dev/null; then
      if ab_lock_is_stale "$lock_path"; then
        stale_path="$lock_path.stale.$$.$attempt"
        if mv "$lock_path" "$stale_path" 2>/dev/null; then
          rm -rf "$stale_path"
        fi
      fi
      rmdir "$reaper_path" 2>/dev/null || true
      continue
    fi

    [ "$attempt" -lt "$attempts" ] || return 1
    sleep "$delay"
  done
  return 1
}

ab_release_lock() {
  local lock_path="${AB_HELD_LOCK:-}"
  local token="${AB_LOCK_TOKEN:-}"
  local recorded
  [ -n "$lock_path" ] && [ -n "$token" ] || return 0
  [ -d "$lock_path" ] && [ ! -L "$lock_path" ] && [ -O "$lock_path" ] || return 1
  recorded="$(sed -n '1p' "$lock_path/token" 2>/dev/null || true)"
  [ "$recorded" = "$token" ] || return 1
  rm -rf "$lock_path"
  unset AB_HELD_LOCK AB_LOCK_TOKEN
}

ab_normalize_port() {
  local value="${1:-}"
  case "$value" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "${#value}" -le 5 ] || return 1
  local normalized=$((10#$value))
  [ "$normalized" -ge 1 ] && [ "$normalized" -le 65535 ] || return 1
  printf '%s' "$normalized"
}

ab_wrapper_root() {
  local tmp="${TMPDIR:-/tmp}"
  local root="${AB_CONNECT_ROOT:-${tmp%/}/agent-browser-connect}"
  while [ "$root" != "/" ] && [ "${root%/}" != "$root" ]; do
    root="${root%/}"
  done
  printf '%s' "$root"
}

ab_prepare_private_dir() {
  local path="$1"
  [ -n "$path" ] && [ "$path" != "/" ] || return 1

  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -d "$path" ] && [ ! -L "$path" ] && [ -O "$path" ] || return 1
  else
    (umask 077; mkdir "$path") 2>/dev/null || {
      [ -d "$path" ] && [ ! -L "$path" ] && [ -O "$path" ] || return 1
    }
  fi
  chmod 700 "$path"
}

ab_owned_directory() {
  local path="$1"
  [ -d "$path" ] && [ ! -L "$path" ] && [ -O "$path" ]
}

ab_default_socket_dir() {
  if [ -n "${AGENT_BROWSER_SOCKET_DIR:-}" ]; then
    printf '%s' "$AGENT_BROWSER_SOCKET_DIR"
  elif [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    printf '%s/agent-browser' "${XDG_RUNTIME_DIR%/}"
  elif [ -n "${HOME:-}" ]; then
    printf '%s/.agent-browser' "${HOME%/}"
  else
    printf '%s/agent-browser' "${TMPDIR:-/tmp}"
  fi
}

ab_endpoint_from_file() {
  local file="$1"
  local wanted_port="$2"
  local file_port ws_path normalized

  [ -f "$file" ] || return 1
  file_port="$(sed -n '1{s/\r$//;p;}' "$file" 2>/dev/null)"
  ws_path="$(sed -n '2{s/\r$//;p;}' "$file" 2>/dev/null)"
  normalized="$(ab_normalize_port "$file_port" 2>/dev/null)" || return 1
  [ "$normalized" = "$wanted_port" ] || return 1
  [ -n "$ws_path" ] || ws_path="/devtools/browser"
  if [[ ! "$ws_path" =~ ^/devtools/browser(/[A-Za-z0-9._-]+)?$ ]]; then
    return 1
  fi
  printf 'ws://127.0.0.1:%s%s' "$wanted_port" "$ws_path"
}

ab_chrome_data_roots() {
  if [ -n "${AB_CHROME_DATA_ROOTS:-}" ]; then
    printf '%s\n' "$AB_CHROME_DATA_ROOTS"
    return
  fi
  [ -n "${HOME:-}" ] || return 0

  case "$(uname -s 2>/dev/null || true)" in
    Darwin)
      printf '%s\n' \
        "$HOME/Library/Application Support/Google/Chrome" \
        "$HOME/Library/Application Support/Google/Chrome Canary" \
        "$HOME/Library/Application Support/Chromium" \
        "$HOME/Library/Application Support/BraveSoftware/Brave-Browser"
      ;;
    Linux)
      printf '%s\n' \
        "$HOME/.config/google-chrome" \
        "$HOME/.config/google-chrome-unstable" \
        "$HOME/.config/chromium" \
        "$HOME/.config/BraveSoftware/Brave-Browser"
      ;;
  esac
}

# Resolve without opening a WebSocket. A WebSocket probe would itself consume a
# Chrome approval and is the failure mode this helper exists to avoid.
ab_resolve_cdp_url() {
  local port="$1"
  local override="${AB_CDP_WS_URL:-}"
  local prefix="ws://127.0.0.1:$port/devtools/browser"
  local file root candidate endpoint

  if [ -n "$override" ]; then
    if [[ ! "$override" =~ ^ws://127\.0\.0\.1:${port}/devtools/browser(/[A-Za-z0-9._-]+)?$ ]]; then
      printf 'AB_CDP_WS_URL must be a local browser WebSocket under %s\n' "$prefix" >&2
      return 1
    fi
    printf '%s' "$override"
    return 0
  fi

  if [ -n "${AB_DEVTOOLS_ACTIVE_PORT_FILE:-}" ]; then
    endpoint="$(ab_endpoint_from_file "$AB_DEVTOOLS_ACTIVE_PORT_FILE" "$port")" || {
      printf 'AB_DEVTOOLS_ACTIVE_PORT_FILE is missing, malformed, or belongs to another port: %s\n' \
        "$AB_DEVTOOLS_ACTIVE_PORT_FILE" >&2
      return 1
    }
    printf '%s' "$endpoint"
    return 0
  fi

  while IFS= read -r root; do
    [ -n "$root" ] || continue
    file="$root/DevToolsActivePort"
    if endpoint="$(ab_endpoint_from_file "$file" "$port")"; then
      printf '%s' "$endpoint"
      return 0
    fi

    [ -d "$root" ] || continue
    while IFS= read -r -d '' candidate; do
      if endpoint="$(ab_endpoint_from_file "$candidate" "$port")"; then
        printf '%s' "$endpoint"
        return 0
      fi
    done < <(find "$root" -mindepth 2 -maxdepth 2 -type f -name DevToolsActivePort -print0 2>/dev/null)
  done < <(ab_chrome_data_roots)

  # Command-line remote debugging and custom profiles may not expose a file in
  # a standard location. Passing the generic browser URL directly still avoids
  # agent-browser's probe-then-reconnect discovery path.
  printf '%s' "$prefix"
}

ab_remove_session_files() {
  local socket_dir="$1"
  local session="$2"
  [ -n "$socket_dir" ] || return 1
  case "$socket_dir" in
    /*) ;;
    *) return 1 ;;
  esac
  ab_validate_session "$session" || return 1
  [ ! -e "$socket_dir" ] || ab_owned_directory "$socket_dir" || return 1

  rm -f \
    "$socket_dir/$session.target" \
    "$socket_dir/$session.config" \
    "$socket_dir/$session.pid" \
    "$socket_dir/$session.version" \
    "$socket_dir/$session.stream" \
    "$socket_dir/$session.sock" \
    "$socket_dir/$session.port" \
    "$socket_dir/$session.target.tmp."* 2>/dev/null
}

# The version the CLI on PATH reports for itself ("agent-browser 0.38.0" -> 0.38.0).
# Empty output means the check is unavailable, and every caller treats that as
# "do not act", never as a mismatch.
ab_cli_version() {
  local bin="$1"
  [ -n "$bin" ] || return 1
  "$bin" --version 2>/dev/null | awk 'NF { print $NF; exit }'
}

# Return 0 only when lsof proves that this daemon owns an established connection
# to the requested Chrome port. Return 1 for no connection and 2 when lsof is
# unavailable, so cleanup can avoid reconnecting merely to tear down.
ab_pid_has_cdp_connection() {
  local pid="$1"
  local port="$2"
  local connections
  command -v lsof >/dev/null 2>&1 || return 2
  connections="$(lsof -nP -a -p "$pid" -iTCP -sTCP:ESTABLISHED 2>/dev/null || true)"
  printf '%s\n' "$connections" \
    | grep -Eq -- "->(127\\.0\\.0\\.1|\\[::1\\]):$port([[:space:]]|\\()"
}
