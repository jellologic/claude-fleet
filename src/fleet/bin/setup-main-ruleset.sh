#!/usr/bin/env sh
# claude-fleet -- bug in this file? SELF-REPORT before fixing: understand it, check/file issues at github.com/jellologic/claude-fleet, then propose a fix. ALL outward actions (issue/comment/push) need HUMAN APPROVAL. See SELF-REPORT.md
# Create/UPDATE the authoritative protect-main GitHub ruleset (idempotent).
# Solo-safe: PR-only, no force-push, no deletion, linear history, admin break-glass.
# No required reviews/checks by default (add when a 2nd reviewer + CI exist).
# Targets refs/heads/main — edit the JSON if your default branch differs.
set -eu
REPO="${1:-$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)}"
[ -n "$REPO" ] || { echo "usage: setup-main-ruleset.sh <owner/repo> (or run in a gh-linked repo)" >&2; exit 1; }
command -v gh >/dev/null || { echo "gh CLI required" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "run 'gh auth login' first" >&2; exit 1; }
admin=$(gh api "repos/$REPO" --jq '.permissions.admin' 2>/dev/null || echo false)
[ "$admin" = true ] || { echo "need admin on $REPO" >&2; exit 1; }
gh api -X PATCH "repos/$REPO" -F allow_rebase_merge=true >/dev/null
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<'JSON'
{
  "name": "protect-main", "target": "branch", "enforcement": "active",
  "bypass_actors": [ { "actor_type": "RepositoryRole", "actor_id": 5, "bypass_mode": "always" } ],
  "conditions": { "ref_name": { "include": ["refs/heads/main"], "exclude": [] } },
  "rules": [
    { "type": "deletion" }, { "type": "non_fast_forward" }, { "type": "required_linear_history" },
    { "type": "pull_request", "parameters": {
        "required_approving_review_count": 0, "require_code_owner_review": false,
        "dismiss_stale_reviews_on_push": true, "require_last_push_approval": false,
        "required_review_thread_resolution": true } }
  ]
}
JSON
ID=$(gh api "repos/$REPO/rulesets" --jq '.[] | select(.name=="protect-main") | .id' 2>/dev/null | head -n1)
if [ -n "$ID" ]; then gh api -X PUT "repos/$REPO/rulesets/$ID" --input "$TMP" >/dev/null; echo "Updated protect-main on $REPO";
else gh api -X POST "repos/$REPO/rulesets" --input "$TMP" >/dev/null; echo "Created protect-main on $REPO"; fi
echo "main is now PR-only, no force-push, linear (admins may break-glass)."
echo "Recovery: gh api repos/$REPO/rulesets ; gh api -X DELETE repos/$REPO/rulesets/<id>"
