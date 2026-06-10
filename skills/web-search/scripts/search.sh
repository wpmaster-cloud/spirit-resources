#!/usr/bin/env bash
# search.sh — web search with curl+jq: query in, "title / url / snippet" out.
#
# Usage:
#   search.sh "query" [-n N] [--days N] [--provider NAME] [--json]
#
#   -n N             max results (default 8)
#   --days N         freshness: 1 -> past day, <=7 -> week, <=31 -> month, else year
#   --provider NAME  tavily | brave | serper | searxng | ddg   (default: auto-pick)
#   --json           print normalized JSON instead of the readable list:
#                    {answer, results:[{title,url,snippet}]}
#
# Auto-pick: the first provider whose credential is set, in the order
#   TAVILY_API_KEY -> BRAVE_API_KEY -> SERPER_API_KEY -> SEARXNG_URL -> ddg (keyless).
# SEARCH_PROVIDER in the environment overrides the order; --provider overrides both.
#
# Credentials: the environment wins; otherwise the first existing file of
# $SEARCH_CONFIG, search/config.env, skills/web-search/config.env is sourced.
# Keys, free-tier limits, and error codes: ../references/providers.md.

set -euo pipefail

command -v curl >/dev/null 2>&1 || { echo "search.sh: curl is required" >&2; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "search.sh: jq is required"   >&2; exit 1; }

QUERY="" MAX=8 DAYS="" PROVIDER="" RAW=0
while [ $# -gt 0 ]; do
  case "$1" in
    -n)         MAX="${2:?-n needs a number}"; shift 2 ;;
    --days)     DAYS="${2:?--days needs a number}"; shift 2 ;;
    --provider) PROVIDER="${2:?--provider needs a name}"; shift 2 ;;
    --json)     RAW=1; shift ;;
    -h|--help)  sed -n '2,19p' "$0" | cut -c3-; exit 0 ;;
    -*)         echo "search.sh: unknown flag $1 (try --help)" >&2; exit 2 ;;
    *)          QUERY="${QUERY:+$QUERY }$1"; shift ;;
  esac
done
[ -n "$QUERY" ] || { echo 'usage: search.sh "query" [-n N] [--days N] [--provider tavily|brave|serper|searxng|ddg] [--json]' >&2; exit 2; }
case "$MAX$DAYS" in *[!0-9]*) echo "search.sh: -n and --days want plain numbers" >&2; exit 2 ;; esac

# --- credentials: env wins; else source the first config file that exists ----
if [ -z "${TAVILY_API_KEY:-}${BRAVE_API_KEY:-}${SERPER_API_KEY:-}${SEARXNG_URL:-}" ]; then
  for _cfg in "${SEARCH_CONFIG:-}" "search/config.env" "skills/web-search/config.env" \
              "$(dirname "$0")/../config.env"; do
    if [ -n "$_cfg" ] && [ -f "$_cfg" ]; then
      # shellcheck disable=SC1090
      . "$_cfg"
      break
    fi
  done
fi

PROVIDER="${PROVIDER:-${SEARCH_PROVIDER:-}}"
if [ -z "$PROVIDER" ]; then
  if   [ -n "${TAVILY_API_KEY:-}" ]; then PROVIDER=tavily
  elif [ -n "${BRAVE_API_KEY:-}" ];  then PROVIDER=brave
  elif [ -n "${SERPER_API_KEY:-}" ]; then PROVIDER=serper
  elif [ -n "${SEARXNG_URL:-}" ];    then PROVIDER=searxng
  else PROVIDER=ddg
  fi
fi

need() { # need VAR_NAME — fail with a pointer instead of a curl 401
  eval "[ -n \"\${$1:-}\" ]" || {
    echo "search.sh: $1 is not set (needed by provider '$PROVIDER') — see skills/web-search/references/providers.md" >&2
    exit 2
  }
}

# --- freshness bucket from --days --------------------------------------------
BUCKET=""
if [ -n "$DAYS" ]; then
  if   [ "$DAYS" -le 1 ];  then BUCKET=day
  elif [ "$DAYS" -le 7 ];  then BUCKET=week
  elif [ "$DAYS" -le 31 ]; then BUCKET=month
  else BUCKET=year
  fi
fi

UA='Mozilla/5.0 (X11; Linux x86_64; rv:124.0) Gecko/20100101 Firefox/124.0'

# --- providers ----------------------------------------------------------------
# Each prints the same normalized envelope: {answer, results:[{title,url,snippet}]}

search_tavily() { # POST api.tavily.com/search; caps max_results at 20
  need TAVILY_API_KEY
  jq -nc --arg q "$QUERY" --argjson n "$(( MAX > 20 ? 20 : MAX ))" --arg t "$BUCKET" \
    '{query:$q, max_results:$n, include_answer:true}
     + (if $t != "" then {time_range:$t} else {} end)' \
  | curl -fsS --max-time 30 https://api.tavily.com/search \
      -H "Authorization: Bearer $TAVILY_API_KEY" \
      -H 'Content-Type: application/json' \
      --data-binary @- \
  | jq '{answer:(.answer // null),
         results:[(.results // [])[] | {title:(.title // ""), url:(.url // ""), snippet:(.content // "")}]}'
}

search_brave() { # GET api.search.brave.com; freshness pd/pw/pm/py; count caps at 20
  need BRAVE_API_KEY
  local fresh=""
  case "$BUCKET" in day) fresh=pd ;; week) fresh=pw ;; month) fresh=pm ;; year) fresh=py ;; esac
  curl -fsS --max-time 30 -G 'https://api.search.brave.com/res/v1/web/search' \
    --data-urlencode "q=$QUERY" \
    --data-urlencode "count=$(( MAX > 20 ? 20 : MAX ))" \
    ${fresh:+--data-urlencode "freshness=$fresh"} \
    -H "X-Subscription-Token: $BRAVE_API_KEY" -H 'Accept: application/json' \
  | jq '{answer:null,
         results:[(.web.results // [])[] | {title:(.title // ""), url:(.url // ""), snippet:(.description // "")}]}'
}

search_serper() { # POST google.serper.dev/search; tbs qdr:d/w/m/y
  need SERPER_API_KEY
  local tbs=""
  case "$BUCKET" in day) tbs=qdr:d ;; week) tbs=qdr:w ;; month) tbs=qdr:m ;; year) tbs=qdr:y ;; esac
  jq -nc --arg q "$QUERY" --argjson n "$MAX" --arg t "$tbs" \
    '{q:$q, num:$n} + (if $t != "" then {tbs:$t} else {} end)' \
  | curl -fsS --max-time 30 https://google.serper.dev/search \
      -H "X-API-KEY: $SERPER_API_KEY" -H 'Content-Type: application/json' \
      --data-binary @- \
  | jq '{answer:(.answerBox.answer // .answerBox.snippet // null),
         results:[(.organic // [])[] | {title:(.title // ""), url:(.link // ""), snippet:(.snippet // "")}]}'
}

search_searxng() { # GET $SEARXNG_URL/search?format=json (must be enabled server-side)
  need SEARXNG_URL
  curl -fsS --max-time 30 -G "${SEARXNG_URL%/}/search" \
    --data-urlencode "q=$QUERY" \
    --data-urlencode 'format=json' \
    ${BUCKET:+--data-urlencode "time_range=$BUCKET"} \
  | jq --argjson n "$MAX" \
      '{answer:null,
        results:[(.results // [])[:$n][] | {title:(.title // ""), url:(.url // ""), snippet:(.content // "")}]}'
}

# DuckDuckGo keyless fallback: scrape the html endpoint. Result links are
# redirect-wrapped (uddg=<urlencoded real url>); ad rows point at y.js and are
# dropped. Brittle by nature — an empty result set often means bot-blocked.
urldecode()  { local d="${1//+/ }"; printf '%b' "${d//%/\\x}"; }
strip_html() { sed -e 's/<[^>]*>//g' -e 's/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g' \
                   -e "s/&#x27;/'/g; s/&#39;/'/g" -e 's/&nbsp;/ /g; s/&amp;/\&/g'; }

search_ddg() {
  local df="" body
  case "$BUCKET" in day) df=d ;; week) df=w ;; month) df=m ;; year) df=y ;; esac
  body="$(curl -fsS --max-time 30 -A "$UA" -G 'https://html.duckduckgo.com/html/' \
    --data-urlencode "q=$QUERY" \
    ${df:+--data-urlencode "df=$df"})"
  if printf '%s' "$body" | grep -q 'anomaly-modal'; then
    echo "search.sh: ddg served a bot challenge instead of results — wait a few minutes between queries, or configure a key provider (references/providers.md)" >&2
    printf '{"answer":null,"results":[]}\n'
    return 0
  fi
  printf '%s' "$body" \
  | tr '\n' ' ' \
  | awk '{
      n = split($0, parts, /class="result__a" href="/)
      for (i = 2; i <= n; i++) {
        part = parts[i]
        href = part;  sub(/".*/, "", href)
        title = part; sub(/^[^>]*>/, "", title); sub(/<\/a>.*/, "", title)
        snip = ""
        if (match(part, /class="result__snippet"[^>]*>/)) {
          snip = substr(part, RSTART + RLENGTH); sub(/<\/a>.*/, "", snip)
        }
        gsub(/\t/, " ", title); gsub(/\t/, " ", snip)
        print href "\t" title "\t" snip
      }
    }' \
  | {
      while IFS="$(printf '\t')" read -r href title snip; do
        case "$href" in *duckduckgo.com/y.js*) continue ;; esac   # skip ads
        url="$href"
        case "$url" in
          *uddg=*) url="${url#*uddg=}"; url="${url%%&*}"; url="$(urldecode "$url")" ;;
          //*)     url="https:$url" ;;
        esac
        jq -nc --arg t "$(printf '%s' "$title" | strip_html)" \
               --arg u "$url" \
               --arg s "$(printf '%s' "$snip" | strip_html)" \
               '{title:$t, url:$u, snippet:$s}'
      done
    } \
  | jq -s --argjson n "$MAX" '{answer:null, results:.[:$n]}'
}

# --- run + render ---------------------------------------------------------------
case "$PROVIDER" in
  tavily|brave|serper|searxng|ddg) ;;
  *) echo "search.sh: unknown provider '$PROVIDER' (tavily|brave|serper|searxng|ddg)" >&2; exit 2 ;;
esac

OUT="$("search_$PROVIDER")"

if [ "$RAW" -eq 1 ]; then
  printf '%s\n' "$OUT" | jq .
  exit 0
fi

if [ "$(printf '%s' "$OUT" | jq '.results | length')" -eq 0 ]; then
  echo "no results from $PROVIDER for: $QUERY" >&2
  [ "$PROVIDER" = ddg ] && \
    echo "(ddg sometimes blocks unattended clients — configure a key provider, see skills/web-search/references/providers.md)" >&2
  exit 1
fi

printf '%s' "$OUT" | jq -r '
  (if (.answer // "") != "" then "answer: " + (.answer | gsub("\\s+"; " ")) + "\n" else empty end),
  (.results | to_entries[] |
    "\(.key + 1). \(.value.title)\n   \(.value.url)"
    + (if (.value.snippet // "") != ""
       then "\n   " + ((.value.snippet | gsub("\\s+"; " "))[0:240])
       else "" end))'
