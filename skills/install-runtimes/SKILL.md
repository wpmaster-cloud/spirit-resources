---
name: install-runtimes
requires: curl, jq, tar
description: >
  Install language runtimes (Go, Node.js, Python) and databases (PostgreSQL,
  Redis, MongoDB, Qdrant) as portable binaries — the right build for the
  machine's CPU and libc, no root and no system package manager needed. Use
  whenever a task needs a runtime or database that isn't installed
  (`command -v` says missing), when `pip`/`npm`/`go` aren't found, when setting
  up a tool the agent will run itself, or when you need a vector/SQL store for
  the memory skill. Covers arch (amd64/arm64) and libc (musl on Alpine vs
  glibc) selection, exact download sources, and how to run each.
---

# Install runtimes & databases (no root)

An ephemeral or non-root agent usually can't `apk add` / `apt install`. The
reliable path is **portable binaries**: download the build that matches the
machine, unpack into a writable prefix, put it on `PATH`. The bundled
`scripts/get.sh` does this for the static-friendly tools; the databases that
have no clean no-root binary are documented with the honest options.

## First: know the machine

Two axes decide every download:

```bash
uname -m                       # x86_64 / amd64  -> amd64       | aarch64 / arm64 -> arm64
ls /lib/ld-musl-* 2>/dev/null  # if this exists you're on musl (Alpine); else glibc
```

**musl vs glibc is the #1 cause of "exec format error" / "not found" on a
binary that downloaded fine.** Alpine (this project's container) is musl;
Debian is glibc. Most vendor tarballs are glibc; on a musl machine you
must pick a musl build or it won't run.

## Language runtimes — use `scripts/get.sh`

```bash
bash scripts/get.sh detect          # show arch / libc / prefix + the PATH line
bash scripts/get.sh go              # latest Go        (static; runs on musl & glibc)
bash scripts/get.sh node            # latest Node LTS  (musl build picked on Alpine)
bash scripts/get.sh uv              # uv: a static Python manager (musl + glibc)
bash scripts/get.sh python 3.12     # CPython via uv
bash scripts/get.sh qdrant          # Qdrant vector DB (static musl/glibc)
bash scripts/get.sh all             # go + node + uv + qdrant
```

Default prefix is `~/.local` (override with `RUNTIME_PREFIX=/work/tools`). After
installing, add it to PATH for the session:

```bash
export PATH="$HOME/.local/bin:$HOME/.local/go/bin:$PATH"
```

Where each comes from, and the musl story:

| Tool | Source | amd64 | arm64 | musl? |
|------|--------|:----:|:----:|-------|
| Go | go.dev/dl (`.linux-<arch>.tar.gz`) | ✅ | ✅ | static — runs anywhere |
| Node.js | nodejs.org/dist; Alpine → unofficial-builds.nodejs.org (`-musl`) | ✅ | ✅ | musl x64 ✅, **musl arm64 often absent** |
| Python | `uv python install` (astral-sh/uv) | ✅ | ✅ | ✅ (uv ships musl) |
| Qdrant | github.com/qdrant/qdrant releases | ✅ | ✅ | ✅ |

If Node musl-arm64 is missing on Alpine, install `gcompat` (needs root) and use
the glibc build, or run Node from a glibc base image instead.

## Using them

```bash
go version                                  # Go
node -v && npm -v                           # Node
uv run python -V                            # Python (uv-managed); uv venv && . .venv/bin/activate; uv pip install ...
~/.local/bin/qdrant                         # Qdrant: REST :6333, gRPC :6334; data in ./storage
```

## Databases

Databases rarely ship a clean static no-root binary. **Default to running them
as a separate service** (a sidecar container / k8s pod) and connecting over the
network — that's simpler and survives the agent being ephemeral. Install
locally only when you own the box.

**Qdrant** — the exception: a static binary (see above). Just run `./qdrant`.

**PostgreSQL** (no root, portable): use the prebuilt tarballs Zonky publishes
for test frameworks — real `postgres`/`initdb` per platform, including Alpine
(musl):

```bash
# arch token: amd64 | arm64v8 ;  add "-alpine" on musl. Pick a version from the listing.
arch=amd64; [ "$(uname -m)" = aarch64 ] && arch=arm64v8
flavor=""; ls /lib/ld-musl-* >/dev/null 2>&1 && flavor="-alpine"
base="https://repo1.maven.org/maven2/io/zonky/test/postgres/embedded-postgres-binaries-linux-${arch}${flavor}"
ver="$(curl -fsSL "$base/maven-metadata.xml" | grep -oE '<release>[^<]+' | sed 's/<release>//')"
curl -fsSL "$base/$ver/embedded-postgres-binaries-linux-${arch}${flavor}-${ver}.jar" -o /tmp/pg.jar
mkdir -p pg && (cd pg && unzip -oq /tmp/pg.jar && tar xf postgres-linux-*.txz)   # -> pg/bin/{initdb,postgres,psql,...}
./pg/bin/initdb -D pgdata -U postgres -A trust
./pg/bin/pg_ctl -D pgdata -l pg.log -o "-p 5432" start
./pg/bin/psql -p 5432 -U postgres -c "SELECT version();"
```
With root instead: `apk add postgresql postgresql-contrib` (Alpine) or the PGDG apt repo. For the **memory skill** you also need pgvector: `apk add postgresql-pgvector` (root), or run the `pgvector/pgvector:pg16` image as a service.

**Redis** — no official static binary. Root: `apk add redis` then
`redis-server --port 6379 --daemonize yes`. No root: run the `redis:7-alpine`
image as a service, or build from source (`make`, needs a compiler).

**MongoDB** — vendor tarballs are **glibc-only (no musl)**, so they won't run on
Alpine. Glibc host: grab `mongodb-linux-<arch>-*.tgz` from fastdl.mongodb.org
and run `./bin/mongod --dbpath data`. On Alpine/ephemeral: run the
`mongo` image as a service and connect.

## Rules

- Always `command -v <tool>` first — it may already be installed.
- Match arch **and** libc before downloading; on Alpine that means musl.
- Prefer `RUNTIME_PREFIX=/work/...` so installs land on a writable, persistent
  path (and, for a containerized agent, can be committed/pushed if needed).
- For databases, ask "service or local?" first — a sidecar/pod is usually the
  right answer for an ephemeral agent.
