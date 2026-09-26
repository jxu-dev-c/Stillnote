# Skills

Agent skills published from this repository. Install one with the
[skills CLI](https://github.com/vercel-labs/skills):

```bash
npx skills add jxu-dev-c/Stillnote
```

| Skill | What it does |
| --- | --- |
| [stillnote](stillnote/SKILL.md) | Read, search, and correct Stillnote meeting transcripts and summaries, and start or stop a recording, through the bundled `stillnote` command. |

Each skill is a directory holding a `SKILL.md` with `name` and `description` frontmatter, plus
any `references/` it needs. `scripts/check-skill.sh` validates them and proves every command a
skill documents exists in the CLI; `./scripts/check.sh` runs it, so CI covers it on every push.
