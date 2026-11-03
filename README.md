# Factory Build Kit — Foundation (E01–E03)

This kit seeds the repository for the Enterprise AI SDLC Factory and gives Claude Code
everything it needs to build the first three epics of the backlog. Copy it into an empty
repository root and commit it before Claude Code writes any code.

## What's in it

| Path | Purpose | Status |
|---|---|---|
| `CLAUDE.md` | Standing instructions Claude Code reads every session | Ready |
| `docs/spec/` | The original blueprint, read-only source of truth | Copied as-is |
| `docs/build/implementation-decisions.md` | D-001…D-017: stack and pattern choices the spec leaves open | Ready |
| `docs/build/repo-structure.md` | Layout, Nx tags, boundary lint config | Ready |
| `docs/build/epics/E01…E03` | Story-by-story briefs with acceptance criteria | Ready |
| `db/migrations/` | Complete schema: 24 tables, triggers, RLS, grants (10 migrations) | **Tested** |
| `db/tests/` | Schema guard suite (25 checks) and RLS coverage check | **Tested** |
| `infra/containers/postgres/init/` | Local role bootstrap (migrator / app role / api login) | **Tested** |
| `agents/` | 8 agent manifests, 8 prompts, tool and model profiles | Validated |
| `policies/` | `enterprise-default` 2026.1 bundle + dev variant | Validated |
| `project-configs/` | Example onboarding config | Validated |

"Tested" means: run on PostgreSQL 16 with node-pg-migrate 9 — all migrations up, all down,
up again; the guard suite passes as both the owner role and the application role; the RLS
coverage check passes and correctly fails when a tenant table lacks RLS.

## How to run the build with Claude Code

1. Create an empty repo (`enterprise-ai-sdlc`), copy the kit's contents to its root, commit.
2. Open Claude Code in the repo. Start each story with a prompt like:

   > Read CLAUDE.md, docs/build/implementation-decisions.md and
   > docs/build/epics/E01-platform-foundation.md. Implement story E01-00 only.
   > Plan first, then build, then show me how each acceptance criterion is verified.

3. Review the diff and the verification output yourself, then merge. One story per PR.
4. Order: E01-00 → E01-01 → E01-02 → E01-03 → E02-01 → E02-02 → E02-03 → E03-02 → E03-01.
   E03 can start in parallel with E02 once E01 is merged, but its API endpoints need E02-02's guard.
5. Close each epic with its "Verification before closing" section, run end to end on a fresh stack.

Stories marked **plan-first** (E02-01) touch security-critical code: have Claude Code stop after
its plan so you can review the approach before any code is written.

## Things only you can do

- Create the GitHub App (or, for LOCAL only, a fine-grained token) for the pilot repository and
  put it where the secret reference in `project-configs/example-project.yaml` points.
- Decide licensing and confirm ownership with respect to your employment agreement before the
  repository becomes public or is used at work.
- Approve each epic. The kit encodes the spec's human-in-the-loop model for building the
  factory too: Claude Code proposes and implements, you approve and merge.

## After E03

The next kit covers E04 (Temporal workflow orchestration), E05 (MCP gateway), E06 (BA and
architect agents with skills) and E08 (approval center), which together reach milestone M3:
feature request to draft PR.
