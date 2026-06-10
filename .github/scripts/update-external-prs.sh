#!/usr/bin/env bash
# Обновляет секцию README между маркерами EXTERNAL_PRS:START / EXTERNAL_PRS:END
# таблицей PR (merged + open) в чужие репозитории. Требует gh (GH_TOKEN) и jq.
set -euo pipefail

USER="chatman-media"
README="${1:-README.md}"
MIN_STARS="${MIN_STARS:-100}" # показывать только репозитории с таким числом звёзд и больше
LIMIT="${LIMIT:-15}"          # строк в таблице, остальные PR уходят в счётчик под ней
PER_REPO="${PER_REPO:-2}"     # не больше стольких PR от одного репозитория (merged в приоритете)

merged=$(gh search prs --author="$USER" --merged --limit 100 \
  --json repository,title,url -- -user:"$USER" | jq 'map(. + {status: "merged"})')
open=$(gh search prs --author="$USER" --state=open --limit 100 \
  --json repository,title,url -- -user:"$USER" | jq 'map(. + {status: "open"})')
prs=$(jq -n --argjson m "$merged" --argjson o "$open" '$m + $o')

if [ "$(echo "$prs" | jq 'length')" -eq 0 ]; then
  echo "No external PRs found, leaving README unchanged."
  exit 0
fi

# Звёзды для каждого репозитория (один запрос на репо)
stars='{}'
for repo in $(echo "$prs" | jq -r '.[].repository.nameWithOwner' | sort -u); do
  count=$(gh api "repos/$repo" --jq '.stargazers_count' 2>/dev/null || echo 0)
  stars=$(echo "$stars" | jq --arg r "$repo" --argjson s "$count" '. + {($r): $s}')
done

filtered=$(echo "$prs" | jq --argjson stars "$stars" --argjson min_stars "$MIN_STARS" '
  map(select(($stars[.repository.nameWithOwner] // 0) >= $min_stars))')
total=$(echo "$filtered" | jq 'length')
merged_count=$(echo "$filtered" | jq 'map(select(.status == "merged")) | length')

table=$(echo "$filtered" | jq -r --argjson stars "$stars" --argjson limit "$LIMIT" --argjson per_repo "$PER_REPO" '
  def fmt_stars: if . >= 1000 then ((. / 100 | floor) / 10 | tostring) + "k" else tostring end;
  def esc: gsub("\\|"; "\\|");
  group_by(.repository.nameWithOwner)
  | map(sort_by(if .status == "merged" then 0 else 1 end) | .[:$per_repo])
  | add
  | sort_by(-($stars[.repository.nameWithOwner] // 0)) | .[:$limit] | .[] |
  "| [\(.repository.nameWithOwner)](https://github.com/\(.repository.nameWithOwner)) ⭐ \($stars[.repository.nameWithOwner] // 0 | fmt_stars) | [\(.title | esc)](\(.url)) | \(if .status == "merged" then "✅ Merged" else "🟢 Open" end) |"
')

search_url="https://github.com/search?q=is%3Apr+author%3A$USER+-user%3A$USER&type=pullrequests"

BLOCK="| Repository | Pull request | Status |
|---|---|---|
$table

**$total pull requests** to external projects with 100+ stars ($merged_count merged) · [see all on GitHub]($search_url)" \
awk '
  /<!-- EXTERNAL_PRS:START -->/ { print; print ENVIRON["BLOCK"]; skip = 1; next }
  /<!-- EXTERNAL_PRS:END -->/ { skip = 0 }
  !skip { print }
' "$README" > "$README.tmp" && mv "$README.tmp" "$README"

echo "Updated $README: $total PRs pass the filter of $(echo "$prs" | jq 'length') found, top $LIMIT in table."
