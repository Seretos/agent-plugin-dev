#!/usr/bin/env bash
# Files a chore(deps) ticket per consumer. Contract: only "could not file the
# ticket at all" is an error. Labels, changelog and board placement are
# best-effort and degrade to ::warning:: annotations.
set -uo pipefail

TAG="v${VERSION}"
LIB="${SOURCE_REPO#*/}"
TITLE="chore(deps): bump ${LIB} to ${TAG}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
BODY_BUDGET=60000

RELEASE_URL="https://github.com/${SOURCE_REPO}/releases/tag/${TAG}"

# --- changelog: the release notes, or a link when unavailable/empty ---------
NOTES="$(gh release view "$TAG" --repo "$SOURCE_REPO" --json body --jq .body 2>/dev/null || true)"
if [ -z "$(printf '%s' "$NOTES" | tr -d '[:space:]')" ]; then
  echo "::warning::No changelog for ${TAG} in ${SOURCE_REPO}; linking the release page instead."
  NOTES="See the release page: ${RELEASE_URL}"
elif [ "${#NOTES}" -gt "$BODY_BUDGET" ]; then
  NOTES="${NOTES:0:$BODY_BUDGET}"$'\n\n'"…truncated — full release notes: ${RELEASE_URL}"
fi

BODY="## Dependency update

A new release of **${LIB}** has been published: \`${TAG}\`.

### What changed

${NOTES}

### Action required

1. Update the pin in \`pyproject.toml\` to:
   \`\`\`
   ${LIB} @ git+https://github.com/${SOURCE_REPO}@${TAG}
   \`\`\`
2. Run this project's test suite to confirm nothing broke.
3. Commit the bump and open a PR."

# --- board: Backlog on the ecosystem board, warn-only -----------------------
add_to_board() {
  local issue_url="$1" item project field option
  [ -z "${BOARD_NUMBER:-}" ] && return 0
  item="$(gh project item-add "$BOARD_NUMBER" --owner "$BOARD_OWNER" --url "$issue_url" --format json 2>/dev/null | jq -r '.id // empty')"
  if [ -z "$item" ]; then
    echo "::warning::Could not add ${issue_url} to board ${BOARD_OWNER}/${BOARD_NUMBER} (token needs the 'project' scope)."
    return 0
  fi
  project="$(gh project view "$BOARD_NUMBER" --owner "$BOARD_OWNER" --format json 2>/dev/null | jq -r '.id // empty')"
  field="$(gh project field-list "$BOARD_NUMBER" --owner "$BOARD_OWNER" --format json 2>/dev/null \
    | jq -r '[.fields[] | select(.name=="Status")][0] | .id // empty')"
  option="$(gh project field-list "$BOARD_NUMBER" --owner "$BOARD_OWNER" --format json 2>/dev/null \
    | jq -r '[.fields[] | select(.name=="Status")][0].options[]? | select(.name=="Backlog") | .id' | head -n1)"
  if [ -z "$project" ] || [ -z "$field" ] || [ -z "$option" ]; then
    echo "::warning::Added ${issue_url} to the board but could not resolve the Status=Backlog option; left in the default column."
    return 0
  fi
  gh project item-edit --id "$item" --project-id "$project" --field-id "$field" \
    --single-select-option-id "$option" >/dev/null 2>&1 \
    || echo "::warning::Could not set Status=Backlog for ${issue_url}."
}

# --- consumers ---------------------------------------------------------------
NORMALIZED="$(printf '%s\n' "$CONSUMERS" | tr ',' '\n')"
failed=0
count=0
{
  echo "### Dependency-update tickets for ${LIB} ${TAG}"
} >> "$SUMMARY"

while IFS= read -r RAW; do
  CONSUMER="$(printf '%s' "$RAW" | xargs)"
  [ -z "$CONSUMER" ] && continue
  count=$((count + 1))

  # Idempotency: reuse an open issue with this exact title.
  EXISTING_URL="$(TITLE="$TITLE" gh api --paginate "repos/${CONSUMER}/issues?state=open&per_page=100" \
    --jq '.[] | select((.pull_request | not) and .title == env.TITLE) | .html_url' 2>/dev/null | head -n1 || true)"
  if [ -n "$EXISTING_URL" ]; then
    echo "Ticket already exists in ${CONSUMER}: ${EXISTING_URL}"
    echo "- ${CONSUMER}: already filed — ${EXISTING_URL}" >> "$SUMMARY"
    continue
  fi

  # Labels: intersect the wish list with what the consumer defines.
  LABEL_ARGS=()
  APPLIED=""
  DEFINED="$(gh label list --repo "$CONSUMER" --limit 200 --json name --jq '.[].name' 2>/dev/null || true)"
  IFS=',' read -ra WANTED <<< "${WANT_LABELS:-}"
  for L in "${WANTED[@]}"; do
    L="$(printf '%s' "$L" | xargs)"
    [ -z "$L" ] && continue
    if printf '%s\n' "$DEFINED" | grep -qxF "$L"; then
      LABEL_ARGS+=(--label "$L")
      APPLIED="${APPLIED:+$APPLIED, }$L"
    else
      echo "::warning::${CONSUMER} defines no label '${L}'; filing without it."
    fi
  done

  ISSUE_URL=""
  if [ "${#LABEL_ARGS[@]}" -gt 0 ]; then
    ISSUE_URL="$(gh issue create --repo "$CONSUMER" --title "$TITLE" --body "$BODY" "${LABEL_ARGS[@]}" 2>/dev/null || true)"
  fi
  # No usable labels, or the labelled attempt failed: file unlabelled.
  if [ -z "$ISSUE_URL" ]; then
    APPLIED=""
    ISSUE_URL="$(gh issue create --repo "$CONSUMER" --title "$TITLE" --body "$BODY" 2>&1 || true)"
    case "$ISSUE_URL" in
      https://*) ;;
      *)
        echo "::error::Filing in ${CONSUMER} failed (check the token's Issues: write scope for that repo): ${ISSUE_URL}"
        echo "- ${CONSUMER}: **FAILED** to file" >> "$SUMMARY"
        failed=1
        continue
        ;;
    esac
  fi

  echo "Ticket opened in ${CONSUMER}: ${ISSUE_URL}"
  echo "- ${CONSUMER}: ${ISSUE_URL} (labels: ${APPLIED:-none})" >> "$SUMMARY"
  add_to_board "$ISSUE_URL"
done <<< "$NORMALIZED"

if [ "$count" -eq 0 ]; then
  echo "::notice::No consumers configured for ${LIB}; no dependency tickets filed."
  echo "- no consumers configured — nothing filed" >> "$SUMMARY"
fi

exit $failed
