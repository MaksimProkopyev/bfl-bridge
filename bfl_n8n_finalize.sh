#!/usr/bin/env bash
# finalize PR18 -> merge -> run GH Action -> show summary (idempotent)
set -Eeuo pipefail
REPO="MaksimProkopyev/bfl-bridge"
PR=18
WF="BFL n8n diag"
FILE=".github/workflows/bfl_n8n_diag.yml"

for t in gh git perl jq; do command -v "$t" >/dev/null || { echo "MISSING_TOOL:$t"; exit 1; }; done
gh auth status >/dev/null || { echo "GH_AUTH_REQUIRED: run 'gh auth login'"; exit 2; }

# 1) clone/update and checkout PR
test -d bfl-bridge/.git || gh repo clone "$REPO" bfl-bridge
cd bfl-bridge
git fetch origin
gh pr checkout "$PR"

# 2) patch jq empty-fallback (idempotent)
if ! grep -q 'value3 // ""' "$FILE"; then
  perl -0777 -pe 's#// \\\"\\")"))#// "")"))#g' -i "$FILE"
  grep -q 'value3 // ""' "$FILE" || { echo "PATCH_NOT_APPLIED"; exit 3; }
  git add "$FILE"; git commit -m "fix(jq): correct empty-fallback quotes in header extraction" || true
  git push
fi

# 3) merge PR into main
gh pr merge "$PR" --merge --delete-branch -R "$REPO" -y

# 4) run workflow and wait
gh workflow run -R "$REPO" "$WF" --ref main
RUN_ID="$(gh run list -R "$REPO" --workflow "$WF" --limit 1 --json databaseId -q '.[0].databaseId')"
test -n "$RUN_ID" || { echo "NO_RUN_FOUND"; exit 4; }
gh run watch -R "$REPO" "$RUN_ID" --interval 5 --exit-status

# 5) print summary slice (REST..NOTES)
LOG="$(gh run view -R "$REPO" "$RUN_ID" --log)"
printf "%s\n" "$LOG" | sed -n '/^REST:/,/^NOTES:/p'
