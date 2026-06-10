---
name: memory
requires: psql, curl, jq
description: >
  Durable long-term memory for the agent on PostgreSQL + pgvector — an "omni"
  store that holds notes, facts, episodes, tasks, and profile in one table with
  both vector embeddings and full-text, and recalls by hybrid (semantic +
  keyword) search. Use whenever the agent should remember something across
  sessions, recall what it knows about a topic/person/decision, build up
  knowledge over time, or when the user says "remember this", "what do you know
  about…", "forget…", or wants persistent memory. Inspired by long-term-memory
  designs in agent systems (reflection, importance, decay). Distinct from
  compact_session, which only shrinks the current transcript.
---

# Memory (PostgreSQL + pgvector)

`compact_session` summarizes the *current* conversation; this skill is the
agent's **durable** memory that survives restarts and pod replacements. It is a
single Postgres table where every memory carries a vector embedding *and* a
full-text index, plus an importance score and usage stats — so recall is hybrid
and self-reinforcing, and the store can forget what stops mattering.

All operations go through `scripts/memory.sh`. Read its header for flags.

## Why one table, two indexes

Pure vector search misses exact terms (names, ids, error codes); pure keyword
search misses paraphrases. `memory.sh recall` runs **both** — nearest-vector
and full-text — and fuses the rankings (reciprocal-rank fusion). That hybrid is
what production agent memories use; it's far more reliable than either alone.

Memory kinds (one `kind` column, query/forget treat them differently):

| kind | meaning | lifecycle |
|------|---------|-----------|
| `profile` | stable facts about the user/agent | never auto-forgotten |
| `fact` | durable learned truths | never auto-forgotten |
| `episode` | things that happened (events, conversations) | decays; feeds consolidation |
| `task` | open / done work items | decays |
| `note` | scratch / misc | decays fastest |
| `summary` | distilled higher-level memory | from consolidation |

## Setup

Needs a reachable Postgres with the `vector` extension. Get one via the
**install-runtimes** skill (portable Postgres + `apk add postgresql-pgvector`),
or run the `pgvector/pgvector:pg16` image as a service. Then:

```bash
export DATABASE_URL='postgres://postgres@localhost:5432/postgres'   # or PG* vars
# embeddings reuse the agent's own LLM creds:
export BASE_URL="$BASE_URL" LLM_API_KEY="$LLM_API_KEY"              # already in the agent's env
export EMBED_MODEL=text-embedding-3-small EMBED_DIM=1536            # must match your model

bash scripts/memory.sh init
```

`EMBED_DIM` must equal your embedding model's dimension (text-embedding-3-small
= 1536, -3-large = 3072). To use a local embedder instead of the API, set
`MEMORY_EMBEDDER=<cmd>` (receives the text as `$1`, prints a JSON number array).

Embeddings call `$BASE_URL/embeddings` — that endpoint must exist on your
provider. It does on OpenAI; it does **not** on Anthropic (and some others), so
an agent running on an `sk-ant-` key needs `MEMORY_EMBEDDER` or a second,
embeddings-capable key/endpoint exported for this script. `consolidate` chats
via `$BASE_URL/chat/completions` using `CHAT_MODEL` (defaults to `MODEL`).

## Daily use

```bash
# store
memory.sh remember "User prefers TypeScript over JS for new services" --kind profile --importance 0.9
memory.sh remember "Deploy failed: missing GIT_TOKEN in agent-main secret" --kind episode --tags deploy
memory.sh remember "Postgres lives at pg.internal:5432" --kind fact --dedup

# recall (hybrid; bumps access_count + last_accessed on every hit)
memory.sh recall "what language does the user like?"
memory.sh recall "deploy secret problem" -k 5

# housekeeping
memory.sh stats            # counts by kind
memory.sh forget           # prune faded low-value memories (protects profile/fact)
memory.sh consolidate      # distill recent episodes -> durable facts (reflection)
```

## How "brilliant management" works here

- **Importance × recency × usage.** `forget` computes a retain score —
  `importance · e^(−age/half-life) · (1+ln(1+access_count))` — and deletes only
  `note`/`task`/`episode` below a threshold. Frequently recalled or important
  memories survive; stale scratch fades. Tune with `MEMORY_HALFLIFE_SEC`
  (default 14 days) and the threshold arg.
- **Reinforcement.** Every `recall` increments `access_count` and refreshes
  `last_accessed` for the hits, so being useful keeps a memory alive — exactly
  what should happen.
- **Reflection / consolidation.** `consolidate` feeds recent un-consolidated
  episodes to the model, extracts durable facts, stores them as `kind=fact`
  (importance 0.8), and marks the episodes done. Run it periodically (pair with
  the **cron** skill) so raw events become compact, lasting knowledge.
- **Dedup.** `remember --dedup` skips a write whose nearest existing memory is
  ≥ 0.95 cosine-similar, preventing near-duplicate buildup.

## Agent loop pattern

A capable agent uses memory on both ends of a turn:

1. **Before acting**, `recall` the task topic and treat the top hits as context.
2. **After acting**, `remember` what's worth keeping — decisions as `fact`,
   what happened as `episode`, the user's stated preferences as `profile`.
3. **Periodically** (cron), `consolidate` then `forget` to keep the store sharp.

## Notes

- The connection (`DATABASE_URL`/`PG*`) and `LLM_API_KEY` are secrets — never echo
  them or write them into memories.
- One shared DB can serve a whole fleet: partition with `--source <agent>` on
  `remember` (or set `MEMORY_SOURCE` once per agent), or use a separate
  database/schema per agent if you need hard isolation.
- This is durable state: for an ephemeral container, the Postgres lives outside
  the pod (a service), so memory survives pod replacement by design. Note the
  stock NetworkPolicy in `ops/agent.yaml` only allows egress on 53/443/80 —
  add 5432 (or run Postgres in-pod) before a deployed agent can reach it.
