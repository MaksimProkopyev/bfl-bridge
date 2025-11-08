#!/usr/bin/env bash
# PR18 -> patch jq -> merge -> run GH Action -> show summary (idempotent)
set -Eeuo pipefail
REPO="MaksimProkopyev/bfl-bridge"; PR=18; WF="BFL n8n diag"; FILE=".github/workflows/bfl_n8n_diag.yml"
command -v gh jq perl git >/dev/null
gh auth status >/dev/null

test -d bfl-bridge/.git || gh repo clone "$REPO" bfl-bridge
cd bfl-bridge && git fetch origin && gh pr checkout "$PR"

# патч (идемпотентно)
if ! grep -q 'value3 // ""' "$FILE"; then
  perl -0777 -pe 's#// \\"\")"))#// "")"))#g' -i "$FILE"
  grep -q 'value3 // ""' "$FILE" || { echo "PATCH_NOT_APPLIED"; exit 3; }
  git add "$FILE"; git commit -m "fix(jq): empty-fallback quotes" || true; git push
fi

# merge и запуск workflow
gh pr merge "$PR" --merge --delete-branch -R "$REPO" -y
gh workflow run -R "$REPO" "$WF" --ref main
sleep 3
RUN_ID="$(gh run list -R "$REPO" --workflow "$WF" --limit 1 --json databaseId -q '.[0].databaseId')"
gh run watch -R "$REPO" "$RUN_ID" --interval 5 --exit-status
gh run view  -R "$REPO" "$RUN_ID" --log | sed -n '/^REST:/,/^NOTES:/p'
