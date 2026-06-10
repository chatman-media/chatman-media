#!/usr/bin/env bash
# Обновляет секцию README между маркерами EXTERNAL_PRS:START / EXTERNAL_PRS:END
# таблицей смерженных PR в чужие репозитории. Требует gh (GH_TOKEN) и jq.
set -euo pipefail

USER="chatman-media"
README="${1:-README.md}"
MIN_STARS="${MIN_STARS:-100}" # показывать только репозитории с таким числом звёзд и больше

prs=$(gh search prs --author="$USER" --merged --limit 100 \
  --json repository,title,url,closedAt -- -user:"$USER")

if [ "$(echo "$prs" | jq 'length')" -eq 0 ]; then
  echo "No external merged PRs found, leaving README unchanged."
  exit 0
fi

# Звёзды для каждого репозитория (один запрос на репо)
stars='{}'
for repo in $(echo "$prs" | jq -r '.[].repository.nameWithOwner' | sort -u); do
  count=$(gh api "repos/$repo" --jq '.stargazers_count' 2>/dev/null || echo 0)
  stars=$(echo "$stars" | jq --arg r "$repo" --argjson s "$count" '. + {($r): $s}')
done

table=$(echo "$prs" | jq -r --argjson stars "$stars" --argjson min_stars "$MIN_STARS" '
  def fmt_stars: if . >= 1000 then ((. / 100 | floor) / 10 | tostring) + "k" else tostring end;
  def esc: gsub("\\|"; "\\|");
  map(select(($stars[.repository.nameWithOwner] // 0) >= $min_stars)) |
  sort_by(.closedAt) | reverse | .[] |
  "| [\(.repository.nameWithOwner)](https://github.com/\(.repository.nameWithOwner)) ⭐ \($stars[.repository.nameWithOwner] // 0 | fmt_stars) | [\(.title | esc)](\(.url)) | \(.closedAt | fromdate | strftime("%b %Y")) |"
')

BLOCK="| Repository | Pull request | Merged |
|---|---|---|
$table" awk '
  /<!-- EXTERNAL_PRS:START -->/ { print; print ENVIRON["BLOCK"]; skip = 1; next }
  /<!-- EXTERNAL_PRS:END -->/ { skip = 0 }
  !skip { print }
' "$README" > "$README.tmp" && mv "$README.tmp" "$README"

echo "Updated $README with $(echo "$table" | grep -c '^|') external PRs (of $(echo "$prs" | jq 'length') found)."
