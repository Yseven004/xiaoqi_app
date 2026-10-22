# Prototype Instructions

Run the local server yourself and open the preview in the browser available to this environment. Do not give the user server-start instructions when you can run it.

## Confirmed detail-page direction · 2026-10-22

- The user approved the three generated detail mockups (plugin, MCP, skill) and requested HTML implementation. The only visual-copy amendment is the official developer identity: 第七世界 is Xiaoqi official. Use `src/config.js` as the single configuration; personal uploads retain their personal author.
- Plugin/MCP share breadcrumb, horizontal identity/actions, gray prompt examples, overview, flat application/capability rows and information. MCP remains under Plugins.
- Skill detail uses a centered title/back, identity, collapsible introduction, three selected report cases and a bottom action. No ratings, stars or rating-related sections.
- Current browser QA preference: the user will inspect the prototype. Do not launch direct Edge/Playwright automation based on an earlier pending request; screenshot and real-device verification remain pending.

Before making substantial visual changes, use the Product Design plugin's `get-context` skill when the visual source is unclear or no longer matches the current goal. When the user gives durable prototype-specific design feedback, preferences, or decisions, record them in `AGENTS.md`.

When implementing from a selected generated mock, treat that image as the source of truth for layout, component anatomy, density, spacing, color, typography, visible content, and hierarchy.

Build app UI in `src/`. Keep `.openai/hosting.json`, `worker/index.js`, `scripts/prepare-sites-build.mjs`, and `tests/sites-worker.test.mjs` intact so the same local prototype can be handed to Sites. Before a Sites handoff, run `npm run build` and `npm run test:sites`; the build must leave `dist/client/index.html`, `dist/server/index.js`, and `dist/.openai/hosting.json`.
