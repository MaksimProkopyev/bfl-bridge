#!/usr/bin/env bash
# BFL — PR18 -> merge -> run workflow -> show report (idempotent)
set -Eeuo pipefail
trap 'echo "FAIL at: $BASH_COMMAND" >&2' ERR

REPO="MaksimProkopyev/bfl-bridge"
PR=18
WF="BFL n8n diag"
FILE=".github/workflows/bfl_n8n_diag.yml"

need() { command -v "$1" >/dev/null || { echo "MISSING_TOOL:$1"; exit 1; }; }
need gh; need git; need jq; need perl

# 0) GH auth
gh auth status >/dev/null || { echo "GH_AUTH_REQUIRED: run 'gh auth login'"; exit 2; }

# 1) clone/update repo (идемпотентно)
if [ ! -d "bfl-bridge/.git" ]; then gh repo clone "$REPO" bfl-bridge; fi
cd bfl-bridge
git fetch --all --prune

# 2) If PR is open -> checkout and patch; if already merged/closed -> skip to workflow
PR_STATE="$(gh pr view "$PR" --json state -q .state 2>/dev/null || echo "UNKNOWN")"

if [ "$PR_STATE" = "OPEN" ]; then
  gh pr checkout "$PR"

  # Patch jq empty-fallback only if ещё не исправлено (идемпотентно)
  if ! grep -q 'value3 // ""' "$FILE"; then
    # несколько безопасных замен на случай разных экранирований
    perl -0777 -pe '
      s/value3\s*\/\/\s*\\"\\"/value3 \/\/ ""/g;
      s#// \\\"\\")"))#// "")"))#g;
      s#// \\"\")"))#// "")"))#g;
    ' -i "$FILE"

    # Проверка, что фиксация прошла
    grep -q 'value3 // ""' "$FILE" || { echo "PATCH_NOT_APPLIED: jq line still wrong"; grep -n 'value3 //' "$FILE" || true; exit 3; }

    git add "$FILE"
    git commit -m "fix(jq): correct empty-fallback quotes in header extraction" || true
    git push || true
  fi

  # Merge PR без пересоздания
  gh pr merge "$PR" --merge --delete-branch -R "$REPO" -y
else
  echo "PR#$PR state: $PR_STATE (skip patch/merge)"
  git checkout main
  git reset --hard origin/main
fi

# 3) Run workflow (Plan B diag/patch) и дождаться завершения
gh workflow run -R "$REPO" "$WF" --ref main

# Подождём, пока ран запишется
sleep 3
RUN_ID="$(gh run list -R "$REPO" --workflow "$WF" --limit 1 --json databaseId -q '.[0].databaseId')"
test -n "$RUN_ID" || { echo "NO_RUN_FOUND"; exit 4; }

gh run watch -R "$REPO" "$RUN_ID" --interval 5 --exit-status

# 4) Выводим полный лог + срез отчёта (REST..NOTES)
LOG="$(gh run view -R "$REPO" "$RUN_ID" --log)"
echo "$LOG"

echo "------ SUMMARY SLICE ------"
printf "%s\n" "$LOG" | sed -n '/^REST:/,/^NOTES:/p' || true
echo "---------------------------"

echo "DONE: Проверь SUMMARY SLICE — нужно видеть REST=200, WEBHOOKS без 401/403 и без WWW-Authenticate, webhook-ноды auth=none, Workflow Active:true."
