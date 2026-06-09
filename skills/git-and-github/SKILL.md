---
name: git-and-github
description: >
  Version control with git, and GitHub repo/PR/issue work using only git and
  the GitHub REST API over curl — no gh CLI required. Use whenever the task
  involves committing, branching, pushing, cloning, diffing, or history; or
  creating/listing PRs, issues, and repos on GitHub. Also the way an ephemeral
  agent persists its own work: commit and push to a remote.
requires: git, curl
---

# Git & GitHub (no gh CLI)

Plain `git` for version control; the GitHub **REST API over `curl`** for
GitHub-side actions. This needs no `gh` binary — only `git`, `curl`, and a
token in `$GIT_TOKEN` (a fine-grained or classic PAT).

## Auth

Set identity once per repo, and authenticate remotes by putting the token in
the URL (never commit it):

```bash
git config user.name  "agent"
git config user.email "agent@example.com"
git remote set-url origin "https://x-access-token:${GIT_TOKEN}@github.com/<owner>/<repo>.git"
```

For the REST API, send the token as a bearer header (shown as `$GIT_TOKEN`
below). Treat the token as a secret: never echo it, never commit it.

## Everyday git

```bash
git status                                   # always look before committing
git switch -c feature/x                       # work on a branch, not main
git add -A && git commit -m "feat: describe the change"
git push -u origin "$(git branch --show-current)"
git log --oneline -n 10
git diff                                      # unstaged   (--staged for staged)
```

## Persist an ephemeral agent's work

The container is disposable; a git remote is the backup. Typical wake-end:

```bash
git add -A && git commit -m "checkpoint: $(date -u +%FT%TZ)" && git push || echo "nothing to push"
```

## GitHub via REST (curl)

One helper, then call any endpoint (https://docs.github.com/rest):

```bash
gh_api() {  # gh_api METHOD PATH [json-body]
  curl -fsSL -X "$1" \
    -H "Authorization: Bearer ${GIT_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com$2" \
    ${3:+-d "$3"}
}
```

```bash
# Open a PR (build the body with jq so quoting is safe)
gh_api POST /repos/<owner>/<repo>/pulls \
  "$(jq -nc --arg t "My title" --arg h "feature/x" --arg b "main" --arg body "Summary." \
        '{title:$t, head:$h, base:$b, body:$body}')"

# List open PRs (pull fields out with jq)
gh_api GET '/repos/<owner>/<repo>/pulls?state=open' | jq -r '.[] | "#\(.number) \(.title)"'

# Create an issue
gh_api POST /repos/<owner>/<repo>/issues "$(jq -nc --arg t "Bug: ..." '{title:$t}')"

# Create a repo for the authenticated user
gh_api POST /user/repos "$(jq -nc --arg n "new-repo" '{name:$n, private:true}')"
```

## Guardrails

- Branch for changes; keep `main` clean. Run `git status` before committing.
- Never commit secrets/tokens; never print `$GIT_TOKEN`.
- `curl -f` makes HTTP errors fail the command instead of returning error JSON
  silently — keep it so a failed API call is visible.
