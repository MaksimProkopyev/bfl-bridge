#!/usr/bin/env bash
# BFL — finalize connect via Codex GPT (PR#18 -> merge -> run action -> show logs)
set -Eeuo pipefail
trap 'echo "FAIL at: $BASH_COMMAND" >&2' ERR

REPO="MaksimProkopyev/bfl-bridge"
PR="18"
WF_NAME="BFL n8n diag"

# 0) Префлайт
for t in gh git perl jq; do
  command -v "$t" >/dev/null || { echo "MISSING_TOOL:$t"; exit 1; }
done
gh auth status >/dev/null || { echo "GH_AUTH_REQUIRED: run 'gh auth login' (web)"; exit 2; }

# 1) Клон/обновление репо (идемпотентно)
if [ ! -d "bfl-bridge/.git" ]; then
  gh repo clone "$REPO" bfl-bridge
fi
cd bfl-bridge
git fetch origin

# 2) Чекаут PR и мини-патч jq-кавычек (идемпотентно)
gh pr checkout "$PR"

FILE=".github/workflows/bfl_n8n_diag.yml"
test -f "$FILE" || { echo "MISSING_FILE:$FILE"; exit 3; }

# Уже исправлено?
if grep -q 'value3 // ""' "$FILE"; then
  echo "PATCH: already OK"
else
  # Попробуем заменить неверный фрагмент на корректный
  perl -0777 -pe 's#// \\\"\\")"))#// "")"))#g' -i "$FILE"
  if ! grep -q 'value3 // ""' "$FILE"; then
    echo "PATCH_NOT_APPLIED: expected pattern not found after replace" >&2
    grep -n 'value3 //' "$FILE" || true
    exit 4
  fi
  git add "$FILE"
  git commit -m "fix(jq): correct empty-fallback quotes in header extraction" || true
  git push
fi

# 3) Merge PR в main (без пересозданий)
gh pr merge "$PR" --merge --delete-branch -R "$REPO" -y

# 4) Запуск GitHub Action (Plan B с egress) и ожидание
gh workflow run -R "$REPO" "$WF_NAME" --ref main

# Получим последний run этого workflow и дождёмся завершения
RUN_ID="$(gh run list -R "$REPO" --workflow "$WF_NAME" --limit 1 --json databaseId -q '.[0].databaseId')"
test -n "$RUN_ID" || { echo "NO_RUN_FOUND"; exit 5; }
gh run watch -R "$REPO" "$RUN_ID" --interval 5 --exit-status

# 5) Вывести логи и краткий срез отчёта
LOG="$(gh run view -R "$REPO" "$RUN_ID" --log)"
echo "$LOG"

echo "------ SUMMARY SLICE ------"
printf "%s\n" "$LOG" | sed -n '/^REST:/,/^NOTES:/p' || true
echo "---------------------------"

echo "DONE: check the SUMMARY SLICE for REST=200, WWW-Authenticate:none on A/B, auth=None on webhook nodes, Workflow Active:true."
