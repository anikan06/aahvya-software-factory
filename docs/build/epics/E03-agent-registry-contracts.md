# E03 — Agent Registry and Contracts

**Spec:** 02 §1, §4, §7 (agent contract, envelopes, permissions), 04 §4, §7 (tool registry, risk tiers), 08 §8 (versioning), 05 §7 (agent endpoints)
**Backlog weeks:** 2–3 · **Priority:** P0 · **Depends on:** E01 (E02 for the API endpoints)
**Milestone contribution:** feeds M2 (BA/architect agents) and M3 (developer execution)

## Goal

Agents become versioned, immutable, reviewable artifacts: defined in git, validated, loaded
into the registry, resolved per project policy, and bound to typed input/output contracts that
every later epic (orchestration, adapters, evaluation) depends on.

## What already exists in the repo
- `agents/manifests/*.yaml` — eight v1.0.0 manifests (BA, architect, architecture-reviewer, frontend-developer, backend-developer, unit-test, security-review, documentation).
- `agents/prompts/` — the shared system prompt and task prompts from spec 02 §5.
- `agents/tool-profiles.yaml`, `agents/model-profiles.yaml`.
- Tables `agent_definitions`, `agent_versions`, `tool_profiles`, `model_profiles`, `evaluation_runs` with immutability triggers (migration 004).

## Stories (in order)

---

### E03-02 — Standard task/result schemas *(do this first: E03-01 validates against it)*

**Build** in `libs/shared/contracts/src/agent-task/v1/`:

`AgentTaskInput` — spec 02 §4 input envelope:
- `schemaVersion: "1.0"`, `workflowId`, `taskId` (uuid), `projectId` (project key), `agent: {id, version}` (semver)
- `objective` (non-empty, ≤ 4 000 chars)
- `artifacts: ArtifactRef[]` — `{type, uri, version, sha256}`; `uri` must start with `artifact://`, sha256 is 64 lowercase hex
- `constraints: {allowedPaths: string[] (glob), prohibitedActions: string[], policyBundleVersion}`; `prohibitedActions` must include `merge` and `production-deploy` (refine)
- `budgets: {maxDurationSeconds, maxToolCalls, maxCostUsd}` — positive, upper-bounded
- `correlation: {factoryRunId, traceId}`

`AgentTaskOutput` — spec 02 §4 output envelope:
- `schemaVersion: "1.0"`, `status: SUCCEEDED | PARTIAL | FAILED | BLOCKED | CANCELLED`
- `summary` (non-empty), `artifacts: ArtifactRef[]`, `findings: Finding[]` (`{severity: CRITICAL|HIGH|MEDIUM|LOW|INFO, title, evidence, location?, remediation?}`)
- `assumptions: string[]`, `risks: string[]`, `questions: string[]`
- `tests?: {passed, failed, skipped}`, `evidence: Evidence[]` (`{type: CI_RUN | TEST_REPORT | SCANNER_REPORT | BUILD_LOG, externalId | uri, conclusion}`)
- `toolCalls: number`, `requiresHumanApproval: boolean`
- `recommendedNextAction: REQUEST_REQUIREMENT_REVIEW | REQUEST_ARCHITECTURE_REVIEW | REQUEST_PR_REVIEW | RETRY | ESCALATE | NONE`
- `error?: {class: TRANSIENT | INVALID_OUTPUT | POLICY_VIOLATION | BUDGET_EXHAUSTED | AGENT_LOGIC | TOOL_FAILURE, message}`

Cross-field rules (Zod refinements — each one is a contract test):
- `tests` present ⇒ `evidence` contains at least one `CI_RUN` or `TEST_REPORT` (spec: an agent cannot self-assert a gate passed).
- `BLOCKED` ⇒ `questions` non-empty. `FAILED` ⇒ `error` present. `SUCCEEDED` ⇒ no `error`.
- `findings` with `CRITICAL` severity ⇒ `status` is not `SUCCEEDED` unless `requiresHumanApproval` is true.

Also:
- `AgentManifest` schema (see `agents/manifests/ba.yaml` for the shape), `ToolProfile`, `ModelProfile`.
- `validateAgentOutput(raw)` returning `{ok: true, value} | {ok: false, issues}` — used by adapters for the single schema-repair attempt (spec 03 §7).
- JSON Schema export for every contract into `schemas/agent-task/v1/*.json` via a `tools` target; CI fails on drift. These are what `input_schema_ref` / `output_schema_ref` (`schema://agent-task-input/1.0`) resolve to.
- Fixtures in `libs/testing/fixtures/agent-task/v1/`: valid SUCCEEDED, PARTIAL, BLOCKED, FAILED, CANCELLED outputs and one invalid fixture per refinement.

**Acceptance criteria** (spec + concrete)
- Input/output schemas are versioned (folder + `schemaVersion` literal).
- Invalid output is rejected with issue paths a human can act on.
- Status values are standardised and exported as a single const used everywhere.
- Contract tests cover success, partial, blocked and failure, plus every refinement.

---

### E03-01 — Agent manifest registry

**Build**
- `libs/domain/agents`: version lifecycle rules mirroring the DB trigger (DRAFT → CANDIDATE → ACTIVE → DEPRECATED; DRAFT → DEPRECATED; CANDIDATE → DEPRECATED), semver comparison, project resolution rules (below). Pure and fully unit-tested.
- `tools` target `agents:sync` (runs as `factory_migrator`, platform catalog rows):
  1. Load and validate `agents/model-profiles.yaml`, `agents/tool-profiles.yaml`, every `agents/manifests/*.yaml`.
  2. Verify every referenced prompt file exists; every tool in a tool profile is a known `server:tool` key (list them in `libs/shared/contracts/src/tools/known-tools.ts` from spec 04 §5); no tool profile contains a T3 tool; every manifest's `toolProfile` and `modelProfile` resolve.
  3. Compute `prompt_hash` (system prompt + task prompt bytes, `\n` normalised, with the single leading `<!-- … -->` comment line stripped — the same text the adapter sends) and `manifest_hash` (RFC 8785 canonical JSON of the resolved manifest, prompt hashes included) per D-013.
  4. Upsert profiles and definitions; insert each version as DRAFT if absent. If the version exists with the same hash → no-op. Same version, different hash → **fail** with "bump the version".
  5. `--promote-candidates` moves DRAFT versions to CANDIDATE.
  6. `--promote <agentKey>@<version> --to ACTIVE --by <issuer>|<subject>` promotes a platform version. Requires a `PASSED` evaluation run, or `--allow-unevaluated` which is refused unless `FACTORY_ENV` is `LOCAL` or `DEV`. Writes a platform-scope `agent.version.promoted` audit event.
  7. `--dry-run` prints the plan. Exit code ≠ 0 on any validation error.

  Platform catalog rows (`organization_id IS NULL`) can only be changed this way: RLS makes them
  read-only to `factory_api` (D-004). The API manages organization-owned agents only.
- `libs/application/agent-registry` + API (all under `/api/v1`, permissions from E02):
  - `GET /agents` (`agent:read`) — platform catalog + org agents, latest ACTIVE version and lifecycle per agent.
  - `GET /agents/{agentKey}` and `GET /agents/{agentKey}/versions` (`agent:read`).
  - `POST /agents` (`agent:register`) — org-scoped definition.
  - `POST /agents/{agentKey}/versions` (`agent:register`) — org-scoped version as DRAFT; prompt content submitted inline, stored as an artifact-style reference.
  - `POST /agents/{agentKey}/versions/{version}/promote` (`agent:promote`) `{to: CANDIDATE | ACTIVE | DEPRECATED, reason}` — organization-owned agents only; platform agents return `403 PLATFORM_AGENT_READ_ONLY`. Promotion to ACTIVE requires a `PASSED` `evaluation_runs` row for that version **unless** the project's/org's active policy bundle sets `agents.allowPromotionWithoutEvaluation: true` (allowed only in bundles bound to LOCAL/DEV; the evaluation gate becomes mandatory in E13). Audited as `agent.version.promoted`.
  - `GET /projects/{projectId}/agents/{agentKey}/resolve` (`project:read`) — returns the version the factory would use.
- **Project-policy-aware resolution** `resolveAgent(projectId, agentKey)`:
  1. Deny if the bound policy bundle lists the agent in `agents.denied`, or defines `agents.allowed` and omits it.
  2. Candidate set = ACTIVE versions of that agent visible to the org (org-owned shadows platform for the same key).
  3. If `projects.config.agents.<key>` pins a semver range, pick the highest version satisfying it; else the highest ACTIVE.
  4. No match → `AGENT_NOT_RESOLVABLE` with the reason. Never fall back to CANDIDATE or DRAFT.
- Portal: agent registry list and detail (versions, status timeline, tool profile with risk tier, model alias, budgets, prompt preview, platform vs organization badge); promote dialog for organization-owned agents when the user holds `agent:promote`.

**Acceptance criteria** (spec + concrete)
- Register agent id, version, owner, prompt/skill refs and tool profile — via `agents:sync` for platform agents and via API for org agents.
- Released versions are immutable: API returns `409 AGENT_VERSION_IMMUTABLE`; the DB trigger is the backstop (test both layers).
- Agent status supports DRAFT, CANDIDATE, ACTIVE, DEPRECATED with only the legal transitions.
- Agent lookup is project-policy aware: tests for denied list, allowed list, semver pin, org shadowing platform, and no-match.
- `agents:sync` on the eight shipped manifests succeeds, and running it twice is a no-op.
- An agent's tool profile can never contain a T3 tool (sync rejects it; DB check is the backstop).
- Architecture reviewer independence: a manifest's `independentOf` list is validated (refers to real agents) and exposed by the resolve endpoint for E04 to enforce.

## Out of scope
Executing agents (E07), skills content (E06), evaluation datasets and scoring (E13),
MCP gateway enforcement of tool profiles (E05 — the profiles defined here are what it enforces).

## Verification before closing the epic
```bash
pnpm agents:sync --dry-run && pnpm agents:sync --promote-candidates
pnpm agents:sync            # second run: no changes
pnpm agents:sync --promote ba@1.0.0 --to ACTIVE --by <alice issuer>|<alice sub> --allow-unevaluated
pnpm nx test shared-contracts domain-agents application-agent-registry
```
Then in the portal: the registry lists all eight agents with `ba` ACTIVE, and
`GET /projects/{id}/agents/ba/resolve` returns `ba@1.0.0` for the onboarded project.
