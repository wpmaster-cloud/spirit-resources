---
name: filesystem-guidance
description: >
  Get shell quoting, escaping, and file-edit syntax right the first time, so you
  stop burning turns retrying a command that keeps failing on a quote, a $, a
  backtick, a glob, or a stray newline. Read this when a command errors with
  "unexpected EOF", "unterminated", "bad substitution", "No such file", or
  "command not found" that looks like a quoting problem; when building a command
  that contains quotes/JSON/regex/here-docs; when editing a file in place; or
  when a filename has spaces or special characters. All guidance uses only the
  tools you already have (bash, plus jq for JSON).
requires: bash
---

# Filesystem & shell-syntax guidance

Your one tool runs `bash -lc "<command>"`. Almost every "stuck in a loop"
failure is a **quoting or escaping** mistake, not a logic mistake. Diagnose the
syntax instead of blindly retrying with different quotes.

## The single most useful habit

When a write or an edit is even slightly tricky, **don't hand-quote it** —
push the payload through a quoted here-doc or a file, where shell metacharacters
are inert. Retry loops almost always come from trying to inline content that
contains the very characters the shell interprets.

## Quoting rules that end the loops

- **Single quotes** `'…'` are literal: nothing inside expands — no `$`, no
  backticks, no `\`. Use them by default. The only thing you can't put inside
  is another single quote.
- A literal single quote inside a single-quoted string is the `'\''` dance:
  `echo 'it'\''s here'` → `it's here`.
- **Double quotes** `"…"` expand `$var`, `$(...)`, and `` `…` ``. Use only when
  you *want* expansion. Inside them, escape a literal `$` or `` ` `` with `\`.
- Diagnose by symptom:
  - `unexpected EOF while looking for matching quote` → an unbalanced `'` or `"`.
  - `bad substitution` → a `${...}` typo, or `$` that should have been literal.
  - a value came out empty / wrong → you used `"` (it expanded) where you meant `'`.

## Writing files: prefer a quoted here-doc

The quoted delimiter `<<'EOF'` makes the whole body literal — no expansion of
`$`, backticks, `\`, or globs. This is the safe way to write scripts, JSON,
configs, anything:

```bash
cat > path/to/file <<'EOF'
literal $HOME, `backticks`, and \backslashes all stay as-is
EOF
```

Use an **unquoted** `<<EOF` only when you deliberately want `$var` expanded in
the body. If the body contains the delimiter word, pick a different one
(`<<'OUTER'`).

## Editing in place: replace the file, don't fight `sed -i`

`sed -i` is not portable (GNU needs `-i`, BSD/macOS needs `-i ''`) and regex
escaping causes loops. For an exact, safe edit, do a whole-file rewrite with a
temp file and `mv` (atomic):

```bash
# exact one-line / one-string replace, verified unique, no regex
tmp=$(mktemp)
old='exact old text'; new='exact new text'
if [ "$(grep -Fc -- "$old" file)" != 1 ]; then echo "not exactly one match; aborting"; else
  awk -v o="$old" -v n="$new" 'index($0,o){sub(o,n)} {print}' file > "$tmp" && mv -- "$tmp" file
fi
```

For structured formats, use a real parser, never regex: `jq` for JSON
(`jq '.key=true' f.json > t && mv t f.json`). Reach for `python3` only if it is
present (`command -v python3`) and the edit is genuinely structural.

## Filenames and paths

- Quote every expansion: `"$path"`, `"$(dirname "$f")"`. Unquoted paths split
  on spaces and expand globs.
- Put `--` before paths so a name starting with `-` isn't read as a flag:
  `rm -- "$f"`, `cp -- "$src" "$dst"`, `grep -- "$pat" "$f"`.
- Iterate files safely with `-print0`/`-0`, never by parsing `ls`:
  `find . -name '*.log' -print0 | xargs -0 -n1 …`.
- Quote glob patterns you want passed literally (to `find`/`rg`):
  `find . -name '*.sh'`, `rg -g '*.ts' 'pattern'`.

## JSON / nested quoting (the worst offender)

Never hand-build JSON by string-concatenation in the shell. Build it with `jq`
and pass values as arguments so quoting is jq's problem, not yours:

```bash
jq -nc --arg msg "$user_text" --argjson n 3 '{message:$msg, count:$n}'
```

To read a field safely: `jq -r '.field' file.json`. To inject a whole file's
contents as a JSON string: `jq -Rs '{body:.}' < file`.

## Search and read (orient before you edit)

```bash
rg --files                 # list tracked-ish files (respects .gitignore)
rg -n 'pattern' path       # search with line numbers
rg -F 'literal $weird'     # fixed-string search, no regex surprises
sed -n '1,120p' -- file    # read a bounded chunk, not the whole file
```

## Reflex when a command fails

1. Read the error — it usually names the syntax problem (EOF, substitution, …).
2. If it's a quoting error, switch the inline string to a quoted here-doc or a
   file. Do **not** just reshuffle quotes and rerun.
3. Re-read the changed lines and run the smallest validation (`bash -n` for a
   script, `jq . file` for JSON) before declaring success.
