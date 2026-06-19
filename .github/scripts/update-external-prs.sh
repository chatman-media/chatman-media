#!/usr/bin/env bash
# Обновляет секцию README между маркерами EXTERNAL_PRS:START / EXTERNAL_PRS:END
# списком ВСЕХ смерженных PR в чужие репозитории с MIN_STARS+ звёзд (сортировка по звёздам ↓).
# Полный список всех PR пишется отдельным файлом ($LIST_FILE). Требует gh (GH_TOKEN) и jq.
set -euo pipefail

USER="chatman-media"
README="${1:-README.md}"
LIST_FILE="${LIST_FILE:-external-prs.md}"  # файл с полным списком всех PR
MIN_STARS="${MIN_STARS:-1000}"   # показывать только репозитории с таким числом звёзд и больше
LIMIT="${LIMIT:-1000}"           # практически без лимита: показываем в README ВСЕ PR из репо ≥ MIN_STARS
TITLE_MAX="${TITLE_MAX:-60}"     # макс. длина заголовка PR в README (длиннее — обрезается с …)
SINCE="${SINCE:-2008-01-01}"     # без ограничения по дате (с основания GitHub) — фильтр только по звёздам

# Человекочитаемый порог звёзд для подписи: 1000 → "1k", 100 → "100"
if [ "$MIN_STARS" -ge 1000 ]; then
  STARS_LABEL="$((MIN_STARS / 1000))k+"
else
  STARS_LABEL="${MIN_STARS}+"
fi

prs=$(gh search prs --author="$USER" --merged --merged-at ">=$SINCE" --limit 100 \
  --json repository,title,url,closedAt -- -user:"$USER")

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
  map(select(($stars[.repository.nameWithOwner] // 0) >= $min_stars))
  | sort_by([($stars[.repository.nameWithOwner] // 0), .closedAt]) | reverse')
total=$(echo "$filtered" | jq 'length')

search_url="https://github.com/search?q=is%3Apr+author%3A$USER+-user%3A$USER+is%3Amerged+merged%3A%3E%3D$SINCE&type=pullrequests"

# Общие jq-определения: звёзды, относительная дата, обрезка заголовка
JQ_DEFS='
  def fmt_stars: if . >= 1000 then ((. / 100 | floor) / 10 | tostring) + "k" else tostring end;
  def fmt_date: fromdateiso8601 | strftime("%b %d, %Y");
  def trunc($n): if (. | length) > $n then (.[:$n-1] | sub(" +$"; "")) + "…" else . end;
  def esc: gsub("\\|"; "\\|");
  def reltime:
    (now - fromdateiso8601) as $s
    | ($s / 86400 | floor) as $d
    | if   $d >= 365 then ($d/365|floor) as $y | "\($y) year\(if $y==1 then "" else "s" end) ago"
      elif $d >= 30  then ($d/30 |floor) as $m | "\($m) month\(if $m==1 then "" else "s" end) ago"
      elif $d >= 14  then ($d/7  |floor) as $w | "\($w) weeks ago"
      elif $d >= 7   then "1 week ago"
      elif $d >= 1   then "\($d) day\(if $d==1 then "" else "s" end) ago"
      else "today" end;
'

# Список последних $LIMIT PR для README (одна строка на PR, без переноса)
list=$(echo "$filtered" | jq -r --argjson stars "$stars" --argjson limit "$LIMIT" --argjson tmax "$TITLE_MAX" "$JQ_DEFS"'
  .[:$limit] | .[] |
  "- `\(.closedAt | reltime)` — [\(.title | trunc($tmax))](\(.url)) · [\(.repository.nameWithOwner)](https://github.com/\(.repository.nameWithOwner)) ⭐ \($stars[.repository.nameWithOwner] // 0 | fmt_stars)"
')

# Хвост: «… ещё N» со ссылкой на полный файл, если PR больше лимита
tail_line=""
if [ "$total" -gt "$LIMIT" ]; then
  tail_line="
- … [and $((total - LIMIT)) more →]($LIST_FILE)"
fi

BLOCK="$list$tail_line

**$total merged pull requests** to external projects with $STARS_LABEL stars · [full list]($LIST_FILE) · [on GitHub]($search_url)"

BLOCK="$BLOCK" awk '
  /<!-- EXTERNAL_PRS:START -->/ { print; print ENVIRON["BLOCK"]; skip = 1; next }
  /<!-- EXTERNAL_PRS:END -->/ { skip = 0 }
  !skip { print }
' "$README" > "$README.tmp" && mv "$README.tmp" "$README"

# Полный список всех PR — отдельным файлом (таблица, абсолютные даты, полные заголовки)
full_rows=$(echo "$filtered" | jq -r --argjson stars "$stars" "$JQ_DEFS"'
  .[] |
  "| \(.closedAt | fmt_date) | [\(.repository.nameWithOwner)](https://github.com/\(.repository.nameWithOwner)) ⭐ \($stars[.repository.nameWithOwner] // 0 | fmt_stars) | [\(.title | esc)](\(.url)) |"
')

cat > "$LIST_FILE" <<EOF
# Open-source contributions

All merged pull requests to external projects with $STARS_LABEL stars, most-starred first.
Auto-generated weekly — see the summary on the [profile README](README.md#-open-source-contributions).

| Merged | Repository | Pull request |
|---|---|---|
$full_rows

**$total merged pull requests** · [see all on GitHub]($search_url)
EOF

echo "Updated $README (last $LIMIT of $total) and $LIST_FILE (all $total)."
