#!/usr/bin/env bash
set -Eeuo pipefail
trap 'c=$?; echo; echo "❌ Ошибка на шаге: ${BASH_COMMAND} (exit ${c})"; exit ${c}' ERR

# --- Предусловия (значения уже у тебя заданы; мы их не печатаем)
: "${WEBHOOK_BASE_URL:?WEBHOOK_BASE_URL required}"
host_wh="$(echo "$WEBHOOK_BASE_URL" | sed -E 's#^https?://([^/]+)/?.*#\1#')"
export NO_PROXY="${NO_PROXY:+$NO_PROXY,}${host_wh},.beget.app,lunirepoko.beget.app,localhost,127.0.0.1"
export no_proxy="$NO_PROXY"

A="${WEBHOOK_BASE_URL%/}/webhook/bfl/leadgen/query-a"
B="${WEBHOOK_BASE_URL%/}/webhook/bfl/leadgen/intake-b"

say(){ printf '%b\n' "$*" >&2; }
probe(){
  local name="$1" url="$2"
  local hd="$(mktemp)"; local code wa
  curl --noproxy "$host_wh" -sS -D "$hd" -o /dev/null -w "%{http_code}" -X POST "$url" -H 'content-type: application/json' -d '{}' || true
  code="$(awk 'toupper($1$2)=="HTTP/1.1"||toupper($1$2)=="HTTP/2"{print $2}' "$hd" | tail -1)"
  wa="$(grep -i '^WWW-Authenticate:' "$hd" || true)"
  rm -f "$hd"
  printf '%-8s → HTTP %s | %s\n' "$name" "${code:-000}" "${wa:-no WWW-Authenticate}"
}

say "→ Предсмок внешних вебхуков (без прокси, без auth)"
probe query-a "$A"
probe intake-b "$B"

# --- Если уже нет 401/403 — ничего не трогаем
need_fix="$( { probe query-a "$A"; probe intake-b "$B"; } 2>/dev/null | awk '/HTTP (401|403)/{f=1} END{print f? "yes":"no"}' )"
if [[ "$need_fix" == "no" ]]; then
  say "✓ Внешний контур не требует авторизации (401/403 не обнаружены). Ничего не меняю."
  exit 0
fi

say "→ Похоже, есть внешняя авторизация. Пытаюсь снять её для /webhook/* через .htaccess (Apache-путь)."

# --- Определяем корень сайта (DOCROOT). Если знаешь точно — заранее экспортни DOCROOT
DOCROOT="${DOCROOT-}"
if [[ -z "$DOCROOT" ]]; then
  # На beget чаще всего ~/www/<домен> или ~/public_html
  candidates=(
    "$HOME/www/$host_wh"
    "$HOME/www/${host_wh%%:*}"
    "$HOME/public_html"
    "$HOME/$host_wh"
  )
  for d in "${candidates[@]}"; do
    [[ -d "$d" ]] && DOCROOT="$d" && break
  done
fi

if [[ -z "$DOCROOT" || ! -d "$DOCROOT" ]]; then
  say "⚠️ Не нашёл DOCROOT. Если есть SSH/SFTP — экспортни DOCROOT=/путь/к/корню сайта и перезапусти."
  say "Если доступа по SSH нет: отключи Password-protected directories/Basic Auth в панели хостинга ИЛИ добавь исключение для /webhook/*."
  exit 2
fi

say "→ DOCROOT: $DOCROOT (скрыт в логе)"

cd "$DOCROOT"

# --- Бэкап текущего .htaccess (если есть)
ts="$(date +%Y%m%d-%H%M%S)"
[[ -f .htaccess ]] && cp -n .htaccess ".htaccess.bak.$ts" || true

# --- Создаём/патчим .htaccess идемпотентно:
# Идея:
#   1) Помечаем /webhook/* переменной среды BFL_ALLOW=1
#   2) Меняем требования авторизации на "RequireAny: env(BFL_ALLOW) ИЛИ valid-user"
# Это оставляет пароль на всём сайте, но снимает его только для /webhook/*
touch .htaccess

# Вставляем SetEnvIfNoCase для /webhook/*
grep -q 'SetEnvIfNoCase[[:space:]]\+Request_URI[[:space:]]\+"^\?/webhook/' .htaccess || {
  printf '\n# BFL: allow webhook paths without auth\nSetEnvIfNoCase Request_URI "^/?webhook/" BFL_ALLOW=1\n' >> .htaccess
}

# Если уже есть блоки Require/valid-user — добавим RequireAny с env
if grep -qi 'Require[[:space:]]\+valid-user' .htaccess || grep -qi '^AuthType[[:space:]]\+Basic' .htaccess; then
  # Добавим наш RequireAny, если его нет
  if ! grep -q 'Require[[:space:]]\+env[[:space:]]\+BFL_ALLOW' .htaccess; then
    cat >> .htaccess <<'HTA'

# BFL: bypass basic auth for /webhook/* on Apache 2.4+
<IfModule mod_authz_core.c>
  <RequireAny>
    Require env BFL_ALLOW
    Require valid-user
  </RequireAny>
</IfModule>

# BFL: fallback for Apache 2.2 (if still present)
<IfModule !mod_authz_core.c>
  Satisfy any
  Order allow,deny
  Allow from all
</IfModule>
HTA
  fi
else
  # Если глобальной Basic нет (но 401/403 всё равно есть), значит защита не через Apache/.htaccess
  say "⚠️ В .htaccess не найдено правил Basic/Auth — вероятно, защита на уровне Nginx/Cloudflare/WAF."
fi

# --- Смок после патча
say "→ Смок после правки .htaccess"
probe query-a "$A"
probe intake-b "$B"

# --- Вывод рекомендаций, если всё ещё 401/403
still_bad="$( { probe query-a "$A"; probe intake-b "$B"; } 2>/dev/null | awk '/HTTP (401|403)/{f=1} END{print f? "yes":"no"}' )"
if [[ "$still_bad" == "yes" ]]; then
  cat >&2 <<'HINT'

❗ Внешняя авторизация НЕ снята .htaccess — почти наверняка она на уровне прокси/панели.
Сделай одно из:
  • В панели хостинга отключи «защиту паролем» (Password-protected) ИЛИ добавь исключение для пути /webhook/*
  • В Nginx (если доступ есть): в server{} добавь:
        location ~* ^/webhook/ { auth_basic off; }
    и перезагрузи сервис.
  • В Cloudflare Access: Rules → Bypass для URL pattern https://<домен>/webhook/*

После изменений перезапусти этот скрипт — коды должны стать 2xx/400/405 (а не 401/403).
HINT
  exit 3
fi

say "✅ Готово: /webhook/* больше не требуют авторизации (нет 401/403 и WWW-Authenticate)."
