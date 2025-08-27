#!/usr/bin/env bash
set -euo pipefail

ENV_FILE=".env"

# ---------- helpers ----------
set_kv () {
  local key="$1"; local val="$2"
  if [ -f "$ENV_FILE" ] && grep -q "^$key=" "$ENV_FILE"; then
    local tmp="${ENV_FILE}.tmp"
    awk -v k="$key" -v v="$val" 'BEGIN{FS=OFS="="} $1==k{$2=v; print; next} {print}' "$ENV_FILE" > "$tmp"
    mv "$tmp" "$ENV_FILE"
  else
    echo "$key=$val" >> "$ENV_FILE"
  fi
}

get_kv () {
  local key="$1"
  [ -f "$ENV_FILE" ] || { touch "$ENV_FILE"; }
  grep -E "^$key=" "$ENV_FILE" | head -n1 | cut -d= -f2- || true
}

gen_rand () { head -c 64 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 24; }
gen_user () { echo "bot_$(head -c 32 /dev/urandom | tr -dc 'a-z0-9' | head -c 10)"; }

ask_required () {
  local var="$1"; local question="$2"
  local current="$(get_kv "$var")"
  local val=""
  while [ -z "${val:-}" ]; do
    if [ -n "$current" ]; then
      printf "%s [%s]: " "$question" "$current"
    else
      printf "%s: " "$question"
    fi
    IFS= read -r val || true
    if [ -z "$val" ] && [ -n "$current" ]; then
      val="$current"
    fi
    [ -z "$val" ] && echo "This value is required."
  done
  set_kv "$var" "$val"
}

ask_db_blank_random () {
  local var="$1"; local question="$2"; local kind="$3" # kind=user|pass|root
  local current="$(get_kv "$var")"
  local input=""
  if [ -n "$current" ]; then
    printf "%s [%s] (blank = random): " "$question" "$current"
  else
    printf "%s (blank = random): " "$question"
  fi
  IFS= read -r input || true
  if [ -z "$input" ]; then
    if [ -n "$current" ]; then
      input="$current"
    else
      if [ "$kind" = "user" ]; then
        input="$(gen_user)"
      else
        input="$(gen_rand)"
      fi
      echo "→ generated: $input"
    fi
  fi
  set_kv "$var" "$input"
}

validate_admins () {
  local val
  val="$(get_kv ADMINS | tr -d ' ')"
  case "$val" in
    *[!0-9,\-]*|"")
      echo "ADMINS must be comma-separated numeric IDs (e.g. 123456789,987654321)."
      ask_required ADMINS "What are your Telegram admin IDs (comma-separated)"
      validate_admins
      ;;
  esac
}

detect_compose () {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
  else
    echo ""
  fi
}

# ---------- defaults ----------
[ -n "$(get_kv MYSQL_HOST)" ] || set_kv "MYSQL_HOST" "mysql"
[ -n "$(get_kv MYSQL_PORT)" ] || set_kv "MYSQL_PORT" "3306"
[ -n "$(get_kv MYSQL_DB)" ]   || set_kv "MYSQL_DB"   "telegram_bot"
[ -n "$(get_kv IMAGE)" ]      || set_kv "IMAGE"      "ghcr.io/rh8831/refbot:latest"

echo "---- Telegram ----"
ask_required "TELEGRAM_TOKEN" "What is your Telegram API token"
ask_required "CHANNEL_ID" "What is your channel ID (@username or -100XXXXXXXXXX)"
ask_required "ADMINS" "What are your Telegram admin IDs (comma-separated)"
validate_admins

echo "---- MySQL (blank = random) ----"
ask_db_blank_random "MYSQL_USER" "MySQL app username" "user"
ask_db_blank_random "MYSQL_PASSWORD" "MySQL app password" "pass"
ask_db_blank_random "MYSQL_ROOT_PASSWORD" "MySQL ROOT password" "root"

echo "---- GHCR login (private image pull) ----"
echo "Image to pull (press Enter to keep default):"
echo "  $(get_kv IMAGE)"
printf "Override IMAGE? (leave blank to keep): "
read -r NEW_IMAGE || true
if [ -n "${NEW_IMAGE:-}" ]; then
  set_kv IMAGE "$NEW_IMAGE"
fi

printf "GitHub username (for ghcr.io): "
read -r REG_USER || true
if [ -n "${REG_USER:-}" ]; then
  printf "GitHub PAT with read:packages (input hidden): "
  read -rs REG_TOKEN || true
  echo
  if [ -n "${REG_TOKEN:-}" ]; then
    if echo "$REG_TOKEN" | docker login ghcr.io -u "$REG_USER" --password-stdin; then
      echo "✓ Logged in to ghcr.io as $REG_USER"
    else
      echo "✗ Login failed. You can run this later:  docker login ghcr.io -u <user> -p <token>"
    fi
  else
    echo "No token provided. Skipping login."
  fi
else
  echo "No username provided. Skipping login."
fi

echo "Saved to .env."

# ---------- start services ----------
COMPOSE_BIN="$(detect_compose || true)"
if [ -n "$COMPOSE_BIN" ] && [ -f "docker-compose.yml" ]; then
  echo "Starting services with $COMPOSE_BIN up -d ..."
  $COMPOSE_BIN up -d
  echo "Done. Use '$COMPOSE_BIN logs -f' to follow logs."
else
  echo "docker compose not found or docker-compose.yml missing. Start services manually later."
fi
