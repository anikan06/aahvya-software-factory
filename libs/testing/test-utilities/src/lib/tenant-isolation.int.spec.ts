import { sql } from 'kysely';
import {
  withTenantContext,
  withUserContext,
} from '@factory/infrastructure/postgres';
import { startPostgresHarness, type PostgresHarness } from './postgres-harness';
import { seedTwoTenants, type SeededTenants } from './seed-tenants';

describe('tenant isolation through withTenantContext (integration, real PostgreSQL + RLS)', () => {
  let harness: PostgresHarness;
  let t: SeededTenants;

  beforeAll(async () => {
    harness = await startPostgresHarness();
    t = await seedTwoTenants(harness.adminDb);
  });

  afterAll(async () => {
    await harness?.stop();
  });

  afterEach(() => {
    expect(harness.poolErrors).toEqual([]);
  });

  const ctxA = () => ({
    organizationId: t.a.organizationId,
    userId: t.a.userId,
  });

  describe('reads', () => {
    it('with no context, no tenant rows are visible (fail closed)', async () => {
      const { db } = harness;
      expect(await db.selectFrom('projects').selectAll().execute()).toEqual([]);
      expect(await db.selectFrom('workflows').selectAll().execute()).toEqual(
        [],
      );
      expect(await db.selectFrom('memberships').selectAll().execute()).toEqual(
        [],
      );
      expect(
        await db.selectFrom('organizations').selectAll().execute(),
      ).toEqual([]);
    });

    it("org A sees only org A's projects and workflows", async () => {
      await withTenantContext(harness.db, ctxA(), async (trx) => {
        const projects = await trx
          .selectFrom('projects')
          .select(['id', 'organization_id'])
          .execute();
        const workflows = await trx
          .selectFrom('workflows')
          .select(['id', 'organization_id'])
          .execute();
        expect(projects).toEqual([
          { id: t.a.projectId, organization_id: t.a.organizationId },
        ]);
        expect(workflows).toEqual([
          { id: t.a.workflowId, organization_id: t.a.organizationId },
        ]);
      });
    });

    it("org A cannot read org B's rows even when asking for them by id", async () => {
      await withTenantContext(harness.db, ctxA(), async (trx) => {
        expect(
          await trx
            .selectFrom('projects')
            .selectAll()
            .where('id', '=', t.b.projectId)
            .execute(),
        ).toEqual([]);
        expect(
          await trx
            .selectFrom('workflows')
            .selectAll()
            .where('id', '=', t.b.workflowId)
            .execute(),
        ).toEqual([]);
      });
    });
  });

  describe('writes', () => {
    it('org A cannot insert a project into org B', async () => {
      await expect(
        withTenantContext(harness.db, ctxA(), (trx) =>
          trx
            .insertInto('projects')
            .values({
              organization_id: t.b.organizationId,
              project_key: 'smuggled',
              name: 'Smuggled',
            })
            .execute(),
        ),
      ).rejects.toThrow(/row-level security/);
    });

    it('org A cannot insert a workflow into org B', async () => {
      await expect(
        withTenantContext(harness.db, ctxA(), (trx) =>
          trx
            .insertInto('workflows')
            .values({
              organization_id: t.b.organizationId,
              project_id: t.b.projectId,
              workflow_type: 'FEATURE_DELIVERY',
              title: 'Smuggled',
              created_by: t.a.userId,
            })
            .execute(),
        ),
      ).rejects.toThrow(/row-level security/);
    });

    it("org A's updates and deletes match zero of org B's rows", async () => {
      const result = await withTenantContext(
        harness.db,
        ctxA(),
        async (trx) => {
          const project = await trx
            .updateTable('projects')
            .set({ name: 'hacked' })
            .where('id', '=', t.b.projectId)
            .executeTakeFirstOrThrow();
          const workflow = await trx
            .updateTable('workflows')
            .set({ title: 'hacked' })
            .where('id', '=', t.b.workflowId)
            .executeTakeFirstOrThrow();
          const deleted = await trx
            .deleteFrom('projects')
            .where('id', '=', t.b.projectId)
            .executeTakeFirstOrThrow();
          return { project, workflow, deleted };
        },
      );
      expect(result.project.numUpdatedRows).toBe(0n);
      expect(result.workflow.numUpdatedRows).toBe(0n);
      expect(result.deleted.numDeletedRows).toBe(0n);

      // Confirm with the owner role (bypasses RLS) that org B's data is untouched.
      const project = await harness.adminDb
        .selectFrom('projects')
        .select('name')
        .where('id', '=', t.b.projectId)
        .executeTakeFirstOrThrow();
      const workflow = await harness.adminDb
        .selectFrom('workflows')
        .select('title')
        .where('id', '=', t.b.workflowId)
        .executeTakeFirstOrThrow();
      expect(project.name).toBe('Project B');
      expect(workflow.title).toBe('Workflow B');
    });

    it("org A's own writes succeed and are visible to org A only", async () => {
      await withTenantContext(harness.db, ctxA(), (trx) =>
        trx
          .insertInto('projects')
          .values({
            organization_id: t.a.organizationId,
            project_key: 'second',
            name: 'Second',
          })
          .execute(),
      );
      const asA = await withTenantContext(harness.db, ctxA(), (trx) =>
        trx.selectFrom('projects').select('project_key').execute(),
      );
      const asB = await withTenantContext(
        harness.db,
        { organizationId: t.b.organizationId, userId: t.b.userId },
        (trx) => trx.selectFrom('projects').select('project_key').execute(),
      );
      expect(asA.map((r) => r.project_key).sort()).toEqual([
        'proj-a',
        'second',
      ]);
      expect(asB.map((r) => r.project_key)).toEqual(['proj-b']);
    });

    it('rolls the whole transaction back when the callback throws', async () => {
      await expect(
        withTenantContext(harness.db, ctxA(), async (trx) => {
          await trx
            .insertInto('projects')
            .values({
              organization_id: t.a.organizationId,
              project_key: 'doomed',
              name: 'Doomed',
            })
            .execute();
          throw new Error('boom');
        }),
      ).rejects.toThrow('boom');
      const rows = await harness.adminDb
        .selectFrom('projects')
        .select('id')
        .where('project_key', '=', 'doomed')
        .execute();
      expect(rows).toEqual([]);
    });
  });

  describe('context lifetime', () => {
    it('does not leak to the next transaction on the same pooled connection', async () => {
      // The harness pool has a single connection, so this next query reuses it.
      await withTenantContext(harness.db, ctxA(), async (trx) => {
        const { rows } = await sql<{
          org: string;
        }>`select current_setting('app.current_org_id', true) as org`.execute(
          trx,
        );
        expect(rows[0]?.org).toBe(t.a.organizationId);
      });
      const { rows } = await sql<{
        org: string | null;
      }>`select current_setting('app.current_org_id', true) as org`.execute(
        harness.db,
      );
      expect(rows[0]?.org ?? '').toBe('');
      expect(
        await harness.db.selectFrom('projects').selectAll().execute(),
      ).toEqual([]);
    });
  });

  describe('withUserContext', () => {
    it("sees the caller's own memberships and their organization, but no tenant rows", async () => {
      await withUserContext(harness.db, { userId: t.a.userId }, async (trx) => {
        const memberships = await trx
          .selectFrom('memberships')
          .select(['organization_id', 'user_id'])
          .execute();
        expect(memberships).toEqual([
          { organization_id: t.a.organizationId, user_id: t.a.userId },
        ]);
        const orgs = await trx
          .selectFrom('organizations')
          .select('id')
          .execute();
        expect(orgs).toEqual([{ id: t.a.organizationId }]);
        expect(await trx.selectFrom('projects').selectAll().execute()).toEqual(
          [],
        );
        expect(await trx.selectFrom('workflows').selectAll().execute()).toEqual(
          [],
        );
      });
    });
  });
});
