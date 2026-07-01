#!/usr/bin/env bash
# Обновляет секцию README между маркерами EXTERNAL_PRS:START / EXTERNAL_PRS:END
# сводкой смерженных PR в чужие репозитории с README_MIN_STARS+ звёзд (за всё время, новые сверху).
# Полный список ВСЕХ принятых PR пишется отдельным файлом ($LIST_FILE). Требует gh (GH_TOKEN) и jq.
set -euo pipefail

USER="chatman-media"
README="${1:-README.md}"
LIST_FILE="${LIST_FILE:-external-prs.md}"      # файл с полным списком всех PR
README_MIN_STARS="${README_MIN_STARS:-5000}"   # README-сводка: только репозитории с таким числом звёзд и больше
FULL_MIN_STARS="${FULL_MIN_STARS:-0}"          # полный список (external-prs.md): ВСЕ принятые PR, без порога
LIMIT="${LIMIT:-20}"             # README: топ-20 (новые сверху); всё сверх — только в полном файле external-prs.md
TITLE_MAX="${TITLE_MAX:-60}"     # макс. длина заголовка PR в README (длиннее — обрезается с …)
SINCE="${SINCE:-2014-01-01}"     # за всё время (аккаунт с 2011)

# Человекочитаемый порог звёзд для подписи README: 5000 → "5k", 100 → "100"
if [ "$README_MIN_STARS" -ge 1000 ]; then
  STARS_LABEL="$((README_MIN_STARS / 1000))k+"
else
  STARS_LABEL="${README_MIN_STARS}+"
fi

prs=$(gh search prs --author="$USER" --merged --merged-at ">=$SINCE" --limit 200 \
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

# README-набор: репозитории ≥ README_MIN_STARS (за всё время), новые сверху
filtered=$(echo "$prs" | jq --argjson stars "$stars" --argjson min_stars "$README_MIN_STARS" '
  map(select(($stars[.repository.nameWithOwner] // 0) >= $min_stars))
  | sort_by([($stars[.repository.nameWithOwner] // 0), .closedAt]) | reverse')
total=$(echo "$filtered" | jq 'length')

# Полный набор: ВСЕ принятые PR ≥ FULL_MIN_STARS (за всё время), новые сверху
full_filtered=$(echo "$prs" | jq --argjson stars "$stars" --argjson min_stars "$FULL_MIN_STARS" '
  map(select(($stars[.repository.nameWithOwner] // 0) >= $min_stars))
  | sort_by(.closedAt) | reverse')
full_total=$(echo "$full_filtered" | jq 'length')

search_url="https://github.com/search?q=is%3Apr+author%3A$USER+-user%3A$USER+is%3Amerged&type=pullrequests"

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

# Сводка для README (одна строка на PR, без переноса) — только репо ≥ README_MIN_STARS
list=$(echo "$filtered" | jq -r --argjson stars "$stars" --argjson limit "$LIMIT" --argjson tmax "$TITLE_MAX" "$JQ_DEFS"'
  .[:$limit] | .[] |
  "**\($stars[.repository.nameWithOwner] // 0 | fmt_stars)** ⭐ [\(.repository.nameWithOwner)](https://github.com/\(.repository.nameWithOwner)) — [\(.title | gsub("`"; "") | trunc($tmax))](\(.url))<br>"
')

# Хвост: «… ещё N» без ссылки (ссылка на полный файл только одна, в сводке ниже)
tail_line=""
if [ "$total" -gt "$LIMIT" ]; then
  tail_line="… and $((total - LIMIT)) more with ${STARS_LABEL} stars, see below<br>"
fi

BLOCK="$list$tail_line

**$total merged pull requests** to external projects with $STARS_LABEL stars · [full list of all $full_total]($LIST_FILE) · [on GitHub]($search_url)"

BLOCK="$BLOCK" awk '
  /<!-- EXTERNAL_PRS:START -->/ { print; print ENVIRON["BLOCK"]; skip = 1; next }
  /<!-- EXTERNAL_PRS:END -->/ { skip = 0 }
  !skip { print }
' "$README" > "$README.tmp" && mv "$README.tmp" "$README"

# Полный список ВСЕХ принятых PR — отдельным файлом (таблица, абсолютные даты, полные заголовки)
full_rows=$(echo "$full_filtered" | jq -r --argjson stars "$stars" "$JQ_DEFS"'
  .[] |
  "| \(.closedAt | fmt_date) | [\(.repository.nameWithOwner)](https://github.com/\(.repository.nameWithOwner)) ⭐ \($stars[.repository.nameWithOwner] // 0 | fmt_stars) | [\(.title | esc)](\(.url)) |"
')

cat > "$LIST_FILE" <<EOF
# Open-source contributions

All merged pull requests to external projects, newest first.
Auto-generated daily — see the summary on the [profile README](README.md#-open-source-contributions).

| Merged | Repository | Pull request |
|---|---|---|
$full_rows

**$full_total merged pull requests** · [see all on GitHub]($search_url)
EOF

echo "Updated $README (≥${README_MIN_STARS}★: $total) and $LIST_FILE (all accepted: $full_total)."
