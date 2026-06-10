# Web-search providers — keys, limits, mappings, errors

`scripts/search.sh` normalizes every backend to the same envelope:

```json
{"answer": "string or null", "results": [{"title": "...", "url": "...", "snippet": "..."}]}
```

This file is the per-provider detail: where the key comes from, what the raw
API looks like, how `--days` maps onto it, and what the error codes mean.

## Tavily (`TAVILY_API_KEY`)

- Sign up: https://app.tavily.com — the key starts with `tvly-`. Free tier
  ~1,000 credits/month (1 basic search = 1 credit).
- Call: `POST https://api.tavily.com/search`, `Authorization: Bearer <key>`,
  JSON body `{query, max_results (≤20), include_answer, time_range}`.
- `--days` → `time_range`: `day` / `week` / `month` / `year`.
- Mapping: `results[].title/url/content` → `title/url/snippet`; `answer` is a
  short synthesized answer — useful directly, but verify anything load-bearing.
- Built for LLM agents: snippets are extracted page content, not store-front
  meta descriptions, so they're substantially more informative than the others.

## Brave Search API (`BRAVE_API_KEY`)

- Sign up: https://api-dashboard.search.brave.com (free plan: ~2,000
  queries/month, 1 request/second; needs a card on file even for free).
- Call: `GET https://api.search.brave.com/res/v1/web/search?q=&count=&freshness=`,
  header `X-Subscription-Token: <key>`. `count` caps at 20 (the script clamps).
- `--days` → `freshness`: `pd` / `pw` / `pm` / `py`.
- Mapping: `web.results[].title/url/description` → `title/url/snippet`.

## Serper (`SERPER_API_KEY`) — Google results

- Sign up: https://serper.dev (free trial credits, then pay-as-you-go).
- Call: `POST https://google.serper.dev/search`, header `X-API-KEY: <key>`,
  JSON body `{q, num, tbs}`.
- `--days` → `tbs`: `qdr:d` / `qdr:w` / `qdr:m` / `qdr:y`.
- Mapping: `organic[].title/link/snippet` → `title/url/snippet`; an
  `answerBox` (when Google shows one) becomes `answer`.

## SearXNG (`SEARXNG_URL`) — self-hosted, keyless

- Run your own instance (the `searxng/searxng` container is the easy path) and
  point `SEARXNG_URL` at it. **`format: json` must be enabled** in the
  instance's `settings.yml` (`search.formats: [html, json]`) or every query
  returns HTTP 403. Public instances usually leave it disabled — assume you
  need your own.
- Call: `GET $SEARXNG_URL/search?q=&format=json&time_range=`.
- `--days` → `time_range`: `day` / `week` / `month` / `year`.
- Mapping: `results[].title/url/content` → `title/url/snippet`; results are
  sliced to `-n` client-side (SearXNG paginates rather than counts).
- From a deployed pod, remember the egress NetworkPolicy: an instance on a
  port other than 443/80 needs that port added to `ops/agent.yaml`.

## DuckDuckGo (keyless fallback)

No API — the script scrapes `https://html.duckduckgo.com/html/?q=…` with a
browser User-Agent and parses the `result__a` / `result__snippet` anchors.
Real result URLs are wrapped in a redirect
(`//duckduckgo.com/l/?uddg=<urlencoded-url>&rut=…`); the script extracts and
url-decodes `uddg`. Rows linking to `duckduckgo.com/y.js` are ads and dropped.
`--days` → `df`: `d` / `w` / `m` / `y`.

Caveats, honestly:

- This is HTML scraping: a markup change can break the parser, and DDG
  bot-detection sometimes serves an empty or CAPTCHA page — the script then
  reports "no results" and suggests a key provider. Don't retry in a tight
  loop; that entrenches the block.
- Snippets are short marketing-grade descriptions; treat them as relevance
  hints only and read the page with web-extraction.
- Fine for occasional interactive lookups; wrong tool for scheduled/cron
  searching — use a key provider there.

## Error codes (all API providers)

| HTTP | Meaning | Fix |
|---|---|---|
| 401 / 403 | bad or missing key (or SearXNG json format disabled) | check the env var / instance settings |
| 402 / 432 | plan or credits exhausted | top up, or switch provider for the month |
| 422 | bad parameter (e.g. count too high) | the script clamps known caps; check flags |
| 429 | rate limit | slow down; free tiers are ~1 req/s |
| 5xx | provider outage | retry later or `--provider` another backend |

`curl -fsS` is used everywhere, so an HTTP error surfaces as a visible
`curl: (22) … error: <code>` on stderr instead of error JSON parsed as results.

## Adding a provider

Add a `search_<name>()` function in `scripts/search.sh` that prints the
normalized envelope above, wire it into the auto-pick chain and the dispatch
`case`, and document the key + mapping here. Keep the contract: `answer` null
unless the API really returns one, `results` always an array, every field a
string.
