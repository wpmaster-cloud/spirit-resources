---
name: web-search
requires: curl, jq
description: >
  Find things on the web — URLs, docs, articles, news, current facts — with
  nothing but curl and jq. One script, five interchangeable backends (Tavily,
  Brave, Serper/Google, a self-hosted SearXNG, and keyless DuckDuckGo as the
  zero-setup fallback), all normalized to the same title/url/snippet output.
  Use whenever the user asks to search, google, look up, or research something
  online, when you need a URL you don't already know, or when the answer may
  have changed since your training data ("what's the latest…", "current
  version of…", "news about…", "find the docs/repo/pricing page for…"). This
  is the discovery half of web work: search here, then read the chosen URLs
  with the web-extraction skill. Trigger phrases: "search for", "google",
  "look up", "find online", "what's the latest", "news about", "research".
---

# Web search (curl-only, five backends)

Discovery only: a query goes in, ranked `title / url / snippet` hits come out.
Reading the pages you picked is the **web-extraction** skill's job — the two
compose: search → choose URLs → extract.

```
skills/web-search/
├── SKILL.md
├── config.env.example      # template for provider keys (one is enough)
├── scripts/
│   └── search.sh           # the whole skill: query -> normalized results
└── references/
    └── providers.md        # keys, limits, field mappings, errors, DDG details
```

## Searching

```bash
S=skills/web-search/scripts

bash $S/search.sh "kubernetes networkpolicy egress dns"          # top 8 hits
bash $S/search.sh "qdrant payload index performance" -n 3        # fewer hits
bash $S/search.sh "anthropic claude api pricing" --days 30       # recent pages only
bash $S/search.sh 'site:github.com session jsonl agent'          # operators pass through
bash $S/search.sh "rust async traits" --json | jq -r '.results[].url'
bash $S/search.sh "..." --provider brave                         # pin a backend
```

Output is a numbered list (`N. title` / url / one snippet line, trimmed), or
with `--json` the raw normalized object:
`{answer, results:[{title,url,snippet}]}` — `answer` is a direct LLM-ready
answer when the provider supplies one (Tavily, sometimes Serper), else null.
`--days N` keeps only recent results, mapped to each provider's nearest
freshness window (past day / week / month / year).

## Providers — works keyless, better with a key

With no configuration at all, the script scrapes DuckDuckGo's HTML endpoint:
fine for occasional lookups, but it's scraping — results are coarse and
unattended clients sometimes get bot-blocked. For anything regular, configure
**one** API provider; the script auto-picks the best configured backend:

| Order | Provider | Credential | Why pick it |
|---|---|---|---|
| 1 | Tavily | `TAVILY_API_KEY` | built for agents; returns a synthesized `answer` + content-rich snippets |
| 2 | Brave | `BRAVE_API_KEY` | fast independent index, clean API, generous free tier |
| 3 | Serper | `SERPER_API_KEY` | real Google results |
| 4 | SearXNG | `SEARXNG_URL` | your own metasearch instance, keyless and private |
| 5 | DuckDuckGo | none | zero-setup fallback (scrape) |

`SEARCH_PROVIDER=<name>` (or `--provider`) overrides the auto-pick. Signup
links, free-tier limits, and per-provider quirks: `references/providers.md`.

**Credentials** follow the usual pattern: the environment wins (export the key
in whatever launches the agent — shell, cron line, or the pod's Secret-backed
`env:`; the runtime does **not** read a `.env` file). Otherwise the script
sources the first existing config file: `$SEARCH_CONFIG`, `search/config.env`,
`skills/web-search/config.env`. Template:

```bash
cp skills/web-search/config.env.example search/config.env   # then fill in
```

Keep the real file out of git (git-ignore it in the agent's folder), and never
echo the keys.

## The handoff: search, then extract

Snippets are for *choosing*, not for *answering* — they're truncated and
sometimes stale. Once you've picked 1–3 promising URLs, read them properly:

```bash
bash skills/web-search/scripts/search.sh "duckdb read parquet from s3" -n 5
# pick the best URL(s), then:
defuddle parse <url> --md          # web-extraction skill, slim path
```

## Gotchas

- **DDG is a scrape, not an API.** If it returns nothing for a query that
  obviously has results, you're likely bot-blocked — the script says so and
  the durable fix is a key provider (Tavily/Brave take ~2 minutes to set up).
  Don't hammer it in a loop; it makes the blocking worse.
- **Rate limits** — free tiers are per-month budgets (see providers.md).
  Batch your thinking into fewer, better queries rather than spraying
  variations; HTTP 429 means slow down, 401 means a bad key, 402/403 usually
  means the quota ran out.
- **Quoting** — pass the query as one argument: `search.sh "two words"`.
  Operators (`site:`, `"exact phrase"`, `-exclude`) ride along inside it.
- **Kubernetes pods** — every backend speaks HTTPS on 443, so the stock
  NetworkPolicy in `ops/agent.yaml` already allows it (a self-hosted SearXNG
  on another port is the one exception — add its port).
- **Freshness ≠ truth** — `--days` filters by page date as the provider sees
  it; verify load-bearing facts by actually reading the page.
