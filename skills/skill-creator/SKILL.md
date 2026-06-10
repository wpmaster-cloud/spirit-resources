---
name: skill-creator
requires: bash
description: Create new skills, modify and improve existing skills, and tune a skill's description so it triggers reliably. Use when users want to author a skill from scratch, edit or improve an existing skill, test a skill against realistic prompts, or make a skill trigger more often when it should (and less when it shouldn't).
---

# Skill Creator

A skill for creating new skills and iteratively improving them.

> **Scope note for this workspace.** The upstream skill-creator ships an automated
> evaluation harness (a benchmark aggregator, an HTML eval-viewer, a description
> auto-optimizer, blind-comparison agents). **Those bundled scripts are not present
> here**, so this version describes the *qualitative* loop only — draft, run a few
> realistic test prompts, review the outputs with the user, and improve. Don't
> reference or try to run `eval-viewer/generate_review.py`, `scripts/*.py`,
> `agents/*.md`, `assets/eval_review.html`, or `references/schemas.md` — they don't
> exist in this checkout.

At a high level, creating a skill goes like this:

- Decide what you want the skill to do and roughly how it should do it
- Write a draft of the skill
- Create a few realistic test prompts and run the skill on them
- Help the user evaluate the results — show them the outputs and gather feedback
- Rewrite the skill based on that feedback (and any glaring flaws you notice)
- Repeat until you're satisfied
- Tune the description so the skill triggers reliably

Your job is to figure out where the user is in this process and jump in. Maybe they
say "I want to make a skill for X" — help narrow what they mean, write a draft,
write test cases, run them, and iterate. Maybe they already have a draft — go
straight to the test/iterate loop. And be flexible: if they say "I don't need
evaluations, just vibe with me," do that instead.

## How skills work in spirit

A skill is just a folder under `skills/<name>/` in the resources repo
(github.com/wpmaster-cloud/spirit-resources) containing a `SKILL.md` (YAML
frontmatter + markdown), optionally with bundled `scripts/` and `references/`.
Skills are **instructions the agent fetches, not installed code**: an agent
clones or downloads the skill folder into its workspace on demand, reads the
full `SKILL.md` with `run_command` (`cat skills/<name>/SKILL.md`) when a task
matches the description, and runs any bundled scripts the same way
(`bash skills/<name>/scripts/foo.sh` from the agent's folder). Discovery is
**progressive disclosure**: name + description first (a directory listing or a
skills index in the agent's session), the body only when needed. There is no
`.skill` package format — to "install" a skill you simply create its folder
under `skills/`.

## Communicating with the user

This skill is used by people across a wide range of familiarity with jargon — from
seasoned engineers to first-time terminal users. Pay attention to context cues:

- "evaluation" and "benchmark" are borderline, but usually OK
- for "JSON" and "assertion", look for clear signs the user knows the terms before
  using them unexplained

It's fine to briefly define a term if you're in doubt.

---

## Creating a skill

### Capture intent

Start by understanding the user's intent. The conversation may already contain a
workflow worth capturing (e.g. "turn this into a skill") — extract what you can from
the history first: the tools used, the sequence of steps, corrections the user made,
input/output formats observed. Then fill gaps with the user and confirm before
proceeding:

1. What should this skill enable the agent to do?
2. When should it trigger? (what user phrases / contexts)
3. What's the expected output format?
4. Are test cases worth it? Skills with objectively checkable outputs (file
   transforms, data extraction, fixed workflow steps) benefit from them; subjective
   skills (writing style, art) often don't. Suggest a default, let the user decide.

### Interview and research

Proactively ask about edge cases, input/output formats, example files, success
criteria, and dependencies. Iron this out before writing test prompts. If useful
MCP tools or web search are available, research similar skills and best practices in
parallel so you come prepared and reduce the burden on the user.

### Write the SKILL.md

Fill in these components:

- **name**: the skill identifier (kebab-case, matches the folder).
- **description**: the primary triggering mechanism — include both *what* the skill
  does AND *when* to use it. All "when to use" info goes here, not in the body.
  Claude tends to **undertrigger** skills, so make descriptions a little "pushy".
  Instead of *"Build a fast dashboard for internal data."* write *"Build a fast
  dashboard for internal data. Use this whenever the user mentions dashboards, data
  visualization, internal metrics, or wants to display any kind of company data,
  even if they don't explicitly say 'dashboard.'"*
- **the rest of the skill :)**

### Skill writing guide

#### Anatomy of a skill

```
skill-name/
├── SKILL.md (required)
│   ├── YAML frontmatter (name, description required)
│   └── Markdown instructions
└── Bundled resources (optional)
    ├── scripts/    - executable code for deterministic/repetitive tasks
    ├── references/ - docs loaded into context as needed
    └── assets/     - files used in output (templates, icons, fonts)
```

#### Progressive disclosure

Three loading levels:
1. **Metadata** (name + description) — always in context (~100 words).
2. **SKILL.md body** — in context whenever the skill triggers (<500 lines ideal).
3. **Bundled resources** — read/executed on demand (unlimited; scripts can run
   without being loaded into context).

Word counts are approximate; go longer when needed. Key patterns:
- Keep SKILL.md under ~500 lines; if it's growing past that, add a layer of
  hierarchy with clear pointers to the follow-up file.
- Reference bundled files clearly, with guidance on *when* to read them.
- For large reference files (>300 lines), include a table of contents.

**Domain organization**: when a skill spans multiple frameworks, split by variant so
the agent reads only what's relevant:

```
cloud-deploy/
├── SKILL.md (workflow + selection)
└── references/
    ├── aws.md
    ├── gcp.md
    └── azure.md
```

#### Principle of least surprise

Skills must not contain malware, exploit code, or anything that could compromise
security. A skill's contents shouldn't surprise the user given its description.
Don't create misleading skills or ones designed to facilitate unauthorized access,
data exfiltration, or other malicious activity. (Benign things like "roleplay as an
X" are fine.)

#### Writing patterns

Prefer the imperative. Define output formats explicitly:

```markdown
## Report structure
ALWAYS use this exact template:
# [Title]
## Executive summary
## Key findings
## Recommendations
```

Include examples:

```markdown
## Commit message format
Input: Added user authentication with JWT tokens
Output: feat(auth): implement JWT-based authentication
```

#### Writing style

Explain *why* things matter rather than piling on heavy-handed MUSTs — today's
models have good theory of mind and a well-explained "why" generalizes far better
than a rigid rule. Keep the skill general, not overfit to specific examples. Write a
draft, then reread it with fresh eyes and improve.

---

## Testing a skill

After drafting, write 2-3 realistic test prompts — the kind of thing a real user
would actually type, with concrete detail (file paths, column names, a bit of
backstory). Share them: *"Here are a few test cases I'd like to try. Do these look
right, or want to add more?"* Then run them.

For each test prompt, compare **with the skill** against a **baseline**:

- **With skill**: complete the task following the skill's `SKILL.md`.
- **Baseline**: complete the same prompt *without* the skill (for a new skill), or
  with the *previous* version (when improving one — snapshot it first with
  `cp -r skills/<name> /tmp/<name>-snapshot`).

If you can spawn subagents (see skills/agent-workshop), run the with-skill and
baseline runs as two separate agents so they finish together and you get an
independent perspective. If not, just run them inline, one at a time — you wrote the
skill and you're running it, so it's less rigorous, but the human review step
compensates.

Save outputs somewhere inspectable (e.g. `skills/<name>-workspace/iteration-1/eval-<id>/`)
and **present the results to the user directly in the conversation**: show each
prompt, the output (render files inline where possible, or save them and point the
user at the path to download), and ask for feedback — *"How does this look? Anything
you'd change?"* Focus your next round of improvements on the cases where the user
had specific complaints; empty feedback means it was fine.

---

## Improving the skill

This is the heart of the loop. You've run the test cases, the user has reviewed, now
make the skill better.

1. **Generalize from the feedback.** Skills are meant to be used across countless
   prompts; you and the user iterate on a few examples only because it's fast. If the
   skill works *only* for those examples, it's useless. Rather than fiddly, overfit
   changes or oppressive MUSTs, when something is stubborn try a different metaphor
   or a different working pattern — it's cheap to try and you may land on something
   great.
2. **Keep the prompt lean.** Remove what isn't pulling its weight. Read the
   *transcripts*, not just the final outputs — if the skill is making the model waste
   time on unproductive detours, cut the parts causing that and see what happens.
3. **Explain the why.** If you catch yourself writing ALL-CAPS ALWAYS/NEVER or rigid
   structures, that's a yellow flag — reframe and explain the reasoning so the model
   understands why it matters. More humane, more powerful, more effective.
4. **Look for repeated work.** If every test run independently wrote a similar helper
   (a `create_docx.py`, a `build_chart.py`), that's a strong signal to bundle that
   script once in `scripts/` and have the skill call it — saving every future
   invocation from reinventing it.

Take your time thinking here; your thinking time isn't the blocker. Draft a revision,
reread it anew, and refine. Get into the user's head and understand what they need.

### The iteration loop

1. Apply your improvements.
2. Rerun all test cases into a new `iteration-<N+1>/` directory (baselines included).
3. Show the user the new outputs (and, helpfully, the previous output side by side).
4. Read the new feedback, improve again, repeat.

Keep going until the user is happy, the feedback is all positive, or you're no longer
making meaningful progress.

---

## Tuning the description (triggering)

The `description` is what determines whether the agent consults the skill, so it's
worth tuning after the skill works. Do this **qualitatively** here (the automated
optimizer isn't bundled in this workspace).

### How triggering works

Skills surface to the agent as name + description (a skills index in its session,
or a directory listing of `skills/`), and the agent decides whether to read the
full `SKILL.md` based on that
description. Crucially, the agent only consults skills for tasks it can't trivially
handle itself — a one-step "read this PDF" may not trigger a skill even on a perfect
description, because basic tools already cover it. Complex, multi-step, or
specialized tasks reliably trigger when the description matches. So design test
queries that are substantive enough that consulting a skill actually helps.

### Build a trigger test set

Write ~20 realistic queries split between **should-trigger** (8-10) and
**should-not-trigger** (8-10), and review them with the user:

- **Should-trigger**: vary the phrasing of the same intent (formal, casual, with
  typos), include cases where the user doesn't name the skill or file type but
  clearly needs it, plus a few uncommon uses and cases where this skill competes with
  another but should win.
- **Should-not-trigger**: the valuable ones are *near-misses* — queries that share
  keywords/concepts but actually need something else. Avoid obviously-irrelevant
  negatives ("write a fibonacci function" for a PDF skill tests nothing); make them
  genuinely tricky.

Make queries concrete and detailed — file paths, column names, company names, a bit
of backstory — not abstract one-liners like "format this data".

### Iterate the wording

Run the should/shouldn't set against the current description (mentally or by actually
prompting), see which cases it gets wrong, and revise the description to fix the
misses without breaking the hits. Bias toward catching undertriggering (the common
failure) while keeping the near-miss negatives out. Show the user before/after and
the reasoning, then update the `SKILL.md` frontmatter.

---

Core loop, one more time for emphasis:

- Figure out what the skill is about
- Draft or edit the skill
- Run it on realistic test prompts (with-skill vs baseline)
- Review the outputs *with the user* and gather feedback
- Improve, and repeat until you're both satisfied
- Tune the description so it triggers reliably

Good luck!
