#!/usr/bin/env bash
# memory.sh — durable "omni" memory for the agent, on PostgreSQL + pgvector.
#
# One table holds every kind of memory (notes, facts, episodes, tasks, profile,
# summaries) with BOTH a vector embedding and a full-text index, so recall is
# hybrid (semantic + keyword) fused by reciprocal-rank. Memories carry an
# importance and an access count; recall reinforces what it returns, forget
# prunes by a recency/importance/usage decay, and consolidate distills recent
# episodes into durable facts (reflection).
#
#   memory.sh init                                  create schema + indexes
#   memory.sh remember "<text>" [--kind fact --importance 0.8 --tags a,b --dedup]
#   memory.sh recall   "<query>" [-k 8]             hybrid search (reinforces hits)
#   memory.sh forget   [threshold]                  prune faded, low-value memories
#   memory.sh consolidate [N]                       distill recent episodes -> facts
#   memory.sh stats                                 counts by kind
#
# Connection: set DATABASE_URL=postgres://user:pass@host:5432/db  (or the
#   standard PGHOST/PGUSER/PGPASSWORD/PGDATABASE vars).
# Embeddings: reuses the agent's LLM creds — BASE_URL + LLM_API_KEY — calling
#   /embeddings (EMBED_MODEL, default text-embedding-3-small; EMBED_DIM 1536).
#   Override with MEMORY_EMBEDDER=<cmd> (gets text on $1, prints a JSON array)
#   to use a local embedder.
set -euo pipefail

EMBED_MODEL="${EMBED_MODEL:-text-embedding-3-small}"
EMBED_DIM="${EMBED_DIM:-1536}"
CHAT_MODEL="${CHAT_MODEL:-${MODEL:-gpt-4o-mini}}"

die() { printf 'memory.sh: %s\n' "$*" >&2; exit 1; }

PSQL=(psql -v ON_ERROR_STOP=1 -qtAX -F'|')
[ -n "${DATABASE_URL:-}" ] && PSQL+=("$DATABASE_URL")
sql() { "${PSQL[@]}" "$@"; }   # ON_ERROR_STOP aborts a multi-statement batch on first error

embed() {  # text -> JSON array literal, e.g. [0.1,-0.2,...]
  if [ -n "${MEMORY_EMBEDDER:-}" ]; then "$MEMORY_EMBEDDER" "$1"; return; fi
  : "${BASE_URL:?set BASE_URL}" "${LLM_API_KEY:?set LLM_API_KEY}"
  curl -fsS "${BASE_URL%/}/embeddings" \
    -H "Authorization: Bearer ${LLM_API_KEY}" -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg m "$EMBED_MODEL" --arg i "$1" '{model:$m,input:$i}')" \
    | jq -ce '.data[0].embedding' || die "embedding request failed"
}

chat() {   # user text -> assistant text (used by consolidate)
  : "${BASE_URL:?set BASE_URL}" "${LLM_API_KEY:?set LLM_API_KEY}"
  curl -fsS "${BASE_URL%/}/chat/completions" \
    -H "Authorization: Bearer ${LLM_API_KEY}" -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg m "$CHAT_MODEL" --arg c "$1" '{model:$m,messages:[{role:"user",content:$c}]}')" \
    | jq -r '.choices[0].message.content // ""'
}

cmd_init() {
  sql -v dim="$EMBED_DIM" <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
CREATE TABLE IF NOT EXISTS memories (
  id            bigserial PRIMARY KEY,
  kind          text NOT NULL DEFAULT 'note',
  content       text NOT NULL,
  embedding     vector(:dim),
  importance    real NOT NULL DEFAULT 0.5,
  access_count  int  NOT NULL DEFAULT 0,
  tags          text[] NOT NULL DEFAULT '{}',
  source        text,
  metadata      jsonb NOT NULL DEFAULT '{}',
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  last_accessed timestamptz,
  fts tsvector GENERATED ALWAYS AS (to_tsvector('english', content)) STORED
);
CREATE INDEX IF NOT EXISTS memories_fts_idx  ON memories USING gin (fts);
CREATE INDEX IF NOT EXISTS memories_kind_idx ON memories (kind);
CREATE INDEX IF NOT EXISTS memories_tags_idx ON memories USING gin (tags);
SQL
  # ANN index needs pgvector >= 0.5 (HNSW); a single -c either succeeds or we note it.
  "${PSQL[@]}" -c "CREATE INDEX IF NOT EXISTS memories_vec_idx ON memories USING hnsw (embedding vector_cosine_ops);" 2>/dev/null \
    || echo "note: no HNSW index (need pgvector >= 0.5); exact vector search still works." >&2
  echo "memory initialised (vector dim=$EMBED_DIM)"
}

cmd_remember() {
  local content="" kind="note" imp="0.5" tags="" source="${MEMORY_SOURCE:-}" dedup=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind) kind="$2"; shift 2 ;;
      --importance) imp="$2"; shift 2 ;;
      --tags) tags="$2"; shift 2 ;;
      --source) source="$2"; shift 2 ;;
      --dedup) dedup=1; shift ;;
      *) content="$1"; shift ;;
    esac
  done
  [ -n "$content" ] || die "remember needs text"
  local emb; emb="$(embed "$content")"
  local tagslit="{${tags}}"

  if [ "$dedup" = 1 ]; then
    local sim
    sim="$(sql -v emb="$emb" <<'SQL'
SELECT COALESCE(1 - (embedding <=> :'emb'::vector), 0)
FROM memories WHERE embedding IS NOT NULL
ORDER BY embedding <=> :'emb'::vector LIMIT 1;
SQL
)"
    if [ -n "$sim" ] && awk "BEGIN{exit !($sim >= 0.95)}"; then
      echo "near-duplicate (sim=$sim); skipped"; return
    fi
  fi

  local id
  id="$(sql -v kind="$kind" -v content="$content" -v imp="$imp" -v emb="$emb" -v tags="$tagslit" -v src="$source" <<'SQL'
INSERT INTO memories (kind, content, importance, embedding, tags, source)
VALUES (:'kind', :'content', :'imp'::real, :'emb'::vector, :'tags'::text[], NULLIF(:'src',''))
RETURNING id;
SQL
)"
  echo "remembered #$id ($kind, importance $imp)"
}

cmd_recall() {
  local query="" k=8
  while [ $# -gt 0 ]; do
    case "$1" in -k) k="$2"; shift 2 ;; *) query="$1"; shift ;; esac
  done
  [ -n "$query" ] || die "recall needs a query"
  case "$k" in ''|*[!0-9]*) die "-k must be an integer" ;; esac
  local emb; emb="$(embed "$query")"
  # Hybrid: rank by vector distance and by full-text, fuse with reciprocal rank
  # (RRF, constant 60). The data-modifying CTE reinforces every returned row.
  sql -v emb="$emb" -v q="$query" -v k="$k" <<'SQL'
WITH params AS (SELECT :'emb'::vector AS qv, plainto_tsquery('english', :'q') AS tq),
vec AS (
  SELECT id, row_number() OVER (ORDER BY embedding <=> (SELECT qv FROM params)) AS r
  FROM memories WHERE embedding IS NOT NULL
  ORDER BY embedding <=> (SELECT qv FROM params) LIMIT 50
),
kw AS (
  SELECT id, row_number() OVER (ORDER BY ts_rank(fts, (SELECT tq FROM params)) DESC) AS r
  FROM memories WHERE fts @@ (SELECT tq FROM params) LIMIT 50
),
fused AS (
  SELECT id, sum(1.0/(60+r)) AS score
  FROM (SELECT * FROM vec UNION ALL SELECT * FROM kw) u GROUP BY id
),
top AS (SELECT id, score FROM fused ORDER BY score DESC LIMIT :k),
bump AS (
  UPDATE memories SET access_count = access_count + 1, last_accessed = now()
  WHERE id IN (SELECT id FROM top) RETURNING id
)
SELECT format('#%s [%s | imp %s | score %s] %s',
  m.id, m.kind, round(m.importance::numeric,2), round(t.score::numeric,4),
  replace(left(m.content,240), E'\n', ' '))
FROM top t JOIN memories m USING (id) ORDER BY t.score DESC;
SQL
}

cmd_forget() {
  local thr="${1:-0.05}" half="${MEMORY_HALFLIFE_SEC:-1209600}"   # 14d half-life
  local n
  n="$(sql -v thr="$thr" -v half="$half" <<'SQL'
WITH scored AS (
  SELECT id,
         importance
         * exp( - extract(epoch FROM now() - COALESCE(last_accessed, created_at)) / :half )
         * (1 + ln(1 + access_count)) AS retain
  FROM memories WHERE kind NOT IN ('profile','fact')
)
DELETE FROM memories WHERE id IN (SELECT id FROM scored WHERE retain < :thr) RETURNING id;
SQL
)"
  printf 'forgot %s memories (retain < %s)\n' "$(printf '%s\n' "$n" | grep -c .)" "$thr"
}

cmd_consolidate() {
  local lim="${1:-50}" rows facts
  rows="$(sql -v lim="$lim" <<'SQL'
SELECT string_agg('- ' || replace(left(content,500), E'\n',' '), E'\n')
FROM (SELECT content FROM memories
      WHERE kind='episode' AND COALESCE((metadata->>'consolidated')::boolean,false)=false
      ORDER BY created_at DESC LIMIT :lim) s;
SQL
)"
  [ -n "$rows" ] || { echo "nothing to consolidate"; return; }
  facts="$(chat "From these recent events, extract durable, reusable facts (stable preferences, identities, decisions, commitments). Reply with ONLY a JSON array of concise fact strings.
$rows")"
  local n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    cmd_remember --kind fact --importance 0.8 --tags consolidated "$f" >/dev/null
    n=$((n+1))
  done < <(printf '%s' "$facts" | jq -r '.[]?' 2>/dev/null || true)
  sql -v lim="$lim" >/dev/null <<'SQL'
UPDATE memories SET metadata = metadata || '{"consolidated":true}'
WHERE id IN (SELECT id FROM memories
             WHERE kind='episode' AND COALESCE((metadata->>'consolidated')::boolean,false)=false
             ORDER BY created_at DESC LIMIT :lim);
SQL
  echo "consolidated recent episodes into $n fact(s)"
}

cmd_stats() {
  sql <<'SQL'
SELECT format('%-9s %4s   avg-imp %s', kind, count(*), round(avg(importance)::numeric,2))
FROM memories GROUP BY kind ORDER BY count(*) DESC;
SELECT format('TOTAL: %s memories, %s embedded', count(*), count(embedding)) FROM memories;
SQL
}

case "${1:-}" in
  init)        shift; cmd_init "$@" ;;
  remember)    shift; cmd_remember "$@" ;;
  recall)      shift; cmd_recall "$@" ;;
  forget)      shift; cmd_forget "$@" ;;
  consolidate) shift; cmd_consolidate "$@" ;;
  stats)       shift; cmd_stats "$@" ;;
  ""|-h|--help) sed -n '2,32p' "$0" ;;
  *) die "unknown command: $1 (init remember recall forget consolidate stats)" ;;
esac
