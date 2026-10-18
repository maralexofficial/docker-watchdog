#!/usr/bin/env bash

set -uo pipefail
umask 077

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

ENV_FILE="${DOCKER_WATCHDOG_ENV:-/etc/watchdog/.env}"
LOG_FILE="/var/log/watchdog.log"
LOCK_FILE="/run/watchdog.lock"
TIMEZONE="Europe/Berlin"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: Configuration file not found: $ENV_FILE" >&2
  exit 1
fi

set -a
source "$ENV_FILE"
set +a

WATCHDOG_LABEL="${WATCHDOG_LABEL:-watchdog.enable}"
WATCHDOG_RESTART_LABEL="${WATCHDOG_RESTART_LABEL:-watchdog.restart}"
WATCHDOG_STATE_DIR="${WATCHDOG_STATE_DIR:-/etc/watchdog/states}"

NTFY_SEND="${NTFY_SEND:-/usr/bin/ntfy-send}"
NTFY_ENV_FILE="${NTFY_ENV_FILE:-/etc/ntfy-send/.env}"
NTFY_TOPIC="${NTFY_TOPIC:-docker-monitoring}"
NTFY_PRIORITY="${NTFY_PRIORITY:-4}"
NTFY_TAGS="${NTFY_TAGS:-warning}"

log() {
  local message
  message="[$(TZ="$TIMEZONE" date '+%Y-%m-%d %H:%M:%S')] $*"

  printf '%s\n' "$message"

  if ! printf '%s\n' "$message" >> "$LOG_FILE"; then
    printf 'ERROR: Cannot write to %s\n' "$LOG_FILE" >&2
  fi
}

notify() {
  local title="$1"
  local message="$2"
  local priority="${3:-$NTFY_PRIORITY}"
  local tags="${4:-$NTFY_TAGS}"
  local topic="${NTFY_TOPIC:-}"

  if [[ -n "$NTFY_SEND" && -x "$NTFY_SEND" ]]; then
    if "$NTFY_SEND" \
      "DEFAULT" \
      "$title" \
      "$message" \
      "--topic=$topic" \
      "--prio=$priority" \
      "--tags=$tags" >/dev/null 2>&1; then
      return 0
    else
      local result=$?
      log "ERROR: ntfy-send failed with exit code $result."
      return "$result"
    fi
  fi

  if ! command -v curl >/dev/null 2>&1; then
    log "ERROR: ntfy-send is unavailable and curl is not installed."
    return 1
  fi

  if [[ ! -f "$NTFY_ENV_FILE" ]]; then
    log "ERROR: ntfy configuration file not found: $NTFY_ENV_FILE"
    return 1
  fi

  local SERVER TOKEN DEFAULT_TOPIC
  SERVER=""
  TOKEN=""
  DEFAULT_TOPIC=""

  set -a
  source "$NTFY_ENV_FILE"
  set +a

  topic="${topic:-$DEFAULT_TOPIC}"

  if [[ -z "$SERVER" || -z "$TOKEN" || -z "$topic" ]]; then
    log "ERROR: ntfy SERVER, TOKEN or topic is missing."
    return 1
  fi

  local -a curl_headers=(
    -H "Authorization: Bearer $TOKEN"
    -H "Title: $title"
    -H "X-Priority: $priority"
    -H "X-Tags: $tags"
  )

  if curl --fail --silent --show-error \
    --output /dev/null \
    "${curl_headers[@]}" \
    --data-binary "$message" \
    "${SERVER%/}/$topic"; then
    return 0
  else
    local result=$?
    log "ERROR: curl notification failed with exit code $result."
    return "$result"
  fi
}

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: Docker command not found." >&2
  exit 1
fi

if ! command -v flock >/dev/null 2>&1; then
  echo "ERROR: flock command not found." >&2
  exit 1
fi

if ! command -v date >/dev/null 2>&1; then
  echo "ERROR: date command not found." >&2
  exit 1
fi

if ! touch "$LOG_FILE"; then
  echo "ERROR: Cannot create log file: $LOG_FILE" >&2
  exit 1
fi

if ! mkdir -p "$WATCHDOG_STATE_DIR"; then
  log "ERROR: Cannot create state directory: $WATCHDOG_STATE_DIR"
  exit 1
fi

chmod 700 "$WATCHDOG_STATE_DIR"

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
  log "Another watchdog instance is already running."
  exit 0
fi

if ! docker info >/dev/null 2>&1; then
  log "ERROR: Docker daemon is unavailable."
  exit 1
fi

get_state() {
  local id="$1"
  local status health

  status="$(docker inspect --format '{{.State.Status}}' "$id" 2>/dev/null)" || {
    echo "unknown"
    return
  }

  health="$(docker inspect \
    --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    "$id" 2>/dev/null)" || {
    echo "unknown"
    return
  }

  if [[ "$status" != "running" ]]; then
    echo "down"
  elif [[ "$health" == "unhealthy" ]]; then
    echo "down"
  elif [[ "$health" == "starting" ]]; then
    echo "starting"
  else
    echo "up"
  fi
}

get_name() {
  docker inspect --format '{{.Name}}' "$1" 2>/dev/null |
    sed 's#^/##'
}

get_label() {
  docker inspect \
    --format "{{index .Config.Labels \"$2\"}}" "$1" 2>/dev/null
}

set_state() {
  local file="$1"
  local state="$2"
  local temp="${file}.tmp.$$"

  if ! printf '%s\n' "$state" > "$temp"; then
    rm -f "$temp"
    return 1
  fi

  if ! mv -f "$temp" "$file"; then
    rm -f "$temp"
    return 1
  fi
}

log "Watchdog check started."

container_ids="$(docker ps -aq \
  --filter "label=${WATCHDOG_LABEL}=true")" || {
  log "ERROR: Could not list Docker containers."
  exit 1
}

UP_COUNT=0
DOWN_COUNT=0
UNKNOWN_COUNT=0

if [[ -z "$container_ids" ]]; then
  log "No containers with ${WATCHDOG_LABEL}=true found."
else
  container_count="$(printf '%s\n' "$container_ids" | wc -l | tr -d ' ')"
  log "Checking $container_count monitored container(s)."

  while IFS= read -r id; do
    [[ -n "$id" ]] || continue

    name="$(get_name "$id")"

    if [[ -z "$name" ]]; then
      log "ERROR: Could not inspect container $id"
      ((UNKNOWN_COUNT += 1))
      continue
    fi

    safe_name="$(printf '%s' "$name" | tr -c 'A-Za-z0-9_.-' '_')"
    state_file="$WATCHDOG_STATE_DIR/${safe_name}.state"

    current="$(get_state "$id")"
    previous=""

    if [[ -f "$state_file" ]]; then
      IFS= read -r previous < "$state_file" || true
    fi

    if [[ "$current" == "unknown" || "$current" == "starting" ]]; then
      log "$name: state is $current; skipping."
      ((UNKNOWN_COUNT += 1))
      continue
    fi

    if [[ "$current" == "down" ]]; then
      if [[ "$previous" != "down" ]]; then
        log "ALERT: $name is down."

        notify \
          "Docker Alert: $name" \
          "Container $name is DOWN on $(hostname)." \
          "$NTFY_PRIORITY" \
          "$NTFY_TAGS" || true

        if ! set_state "$state_file" "down"; then
          log "ERROR: Could not save state for $name"
          ((UNKNOWN_COUNT += 1))
          continue
        fi

        restart_label="$(get_label "$id" "$WATCHDOG_RESTART_LABEL")"

        if [[ "$restart_label" == "true" ]]; then
          log "Attempting restart of $name."

          if docker restart "$id" >/dev/null 2>&1; then
            sleep 2
            current="$(get_state "$id")"

            if [[ "$current" == "up" ]]; then
              log "RECOVERED: $name is running again."

              notify \
                "Docker Recovery: $name" \
                "Container $name is UP again on $(hostname)." \
                "3" \
                "white_check_mark" || true

              if set_state "$state_file" "up"; then
                ((UP_COUNT += 1))
              else
                log "ERROR: Could not save state for $name"
                ((UNKNOWN_COUNT += 1))
              fi
            else
              log "ERROR: $name remains unavailable after restart."
              ((DOWN_COUNT += 1))
            fi
          else
            log "ERROR: Restart failed for $name."
            ((DOWN_COUNT += 1))
          fi
        else
          log "Automatic restart disabled for $name."
          ((DOWN_COUNT += 1))
        fi
      else
        log "$name remains down; no duplicate alert or restart."
        ((DOWN_COUNT += 1))
      fi

      continue
    fi

    if [[ "$current" == "up" ]]; then
      log "OK: $name is running."
      ((UP_COUNT += 1))

      if [[ "$previous" == "down" ]]; then
        log "RECOVERED: $name is running again."

        notify \
          "Docker Recovery: $name" \
          "Container $name is UP again on $(hostname)." \
          "3" \
          "white_check_mark" || true
      elif [[ -z "$previous" ]]; then
        log "INITIALIZED: $name is running."
      fi

      if ! set_state "$state_file" "up"; then
        log "ERROR: Could not save state for $name"
      fi
    fi

  done <<< "$container_ids"
fi

log "Watchdog check completed: $UP_COUNT up, $DOWN_COUNT down, $UNKNOWN_COUNT unknown or starting."

REPORT_DATE="$(TZ="$TIMEZONE" date '+%Y-%m-%d')"
REPORT_HOUR="$(TZ="$TIMEZONE" date '+%H%M')"
REPORT_STATE_FILE="$WATCHDOG_STATE_DIR/daily-report.date"
LAST_REPORT_DATE=""

if [[ -f "$REPORT_STATE_FILE" ]]; then
  IFS= read -r LAST_REPORT_DATE < "$REPORT_STATE_FILE" || true
fi

if [[ "$REPORT_HOUR" -ge 2000 && "$LAST_REPORT_DATE" != "$REPORT_DATE" ]]; then
  log "Sending daily status report."

  REPORT_MESSAGE="Server: $(hostname)
Date: $REPORT_DATE
Monitored: $((UP_COUNT + DOWN_COUNT + UNKNOWN_COUNT))
Running: $UP_COUNT
Down: $DOWN_COUNT
Unknown or starting: $UNKNOWN_COUNT"

  if notify \
    "[Watchdog] Daily docker report" \
    "$REPORT_MESSAGE" \
    "3" \
    "white_check_mark,calendar"; then

    REPORT_TEMP="${REPORT_STATE_FILE}.tmp.$$"

    if printf '%s\n' "$REPORT_DATE" > "$REPORT_TEMP" &&
      mv -f "$REPORT_TEMP" "$REPORT_STATE_FILE"; then
      log "Daily status report sent successfully."
    else
      rm -f "$REPORT_TEMP"
      log "ERROR: Could not save daily report date."
    fi
  else
    log "ERROR: Daily report failed; it will be retried."
  fi
fi

exit 0