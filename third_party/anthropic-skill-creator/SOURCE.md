# Source record

- Project: [Anthropic Skills](https://github.com/anthropics/skills)
- Path: `skills/skill-creator`
- Commit: `8a1541c4a3ffa5a20a5a91de0dcf3f0bab1d1ef4`
- License: Apache License 2.0; see `LICENSE.txt`.
- Imported upstream files are kept unmodified: `SKILL.md`, `agents/{analyzer,comparator,grader}.md`, and `references/schemas.md`.

Xiaoqi uses the upstream authoring guidance and evaluation formats through a
separate adapter. Claude-only tool names and execution instructions are not
used as Xiaoqi runtime calls; the adapter maps the workflow to Xiaoqi's
conversation, draft workspace, resource reader, and Python sandbox.
