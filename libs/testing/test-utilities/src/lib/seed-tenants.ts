import type { Db } from '@factory/infrastructure/postgres';
import {
  asOrganizationId,
  asUserId,
  type OrganizationId,
  type UserId,
} from '@factory/shared/types';

export interface SeededTenant {
  readonly organizationId: OrganizationId;
  readonly userId: UserId;
  readonly projectId: string;
  readonly workflowId: string;
}

export interface SeededTenants {
  readonly a: SeededTenant;
  readonly b: SeededTenant;
}

async function seedTenant(adminDb: Db, key: 'a' | 'b'): Promise<SeededTenant> {
  const org = await adminDb
    .insertInto('organizations')
    .values({ name: `Org ${key.toUpperCase()}`, slug: `org-${key}` })
    .returning('id')
    .executeTakeFirstOrThrow();
  const user = await adminDb
    .insertInto('users')
    .values({
      external_issuer: 'https://idp.test/realms/factory',
      external_subject: `subject-${key}`,
      email: `${key}@example.test`,
    })
    .returning('id')
    .executeTakeFirstOrThrow();
  const project = await adminDb
    .insertInto('projects')
    .values({
      organization_id: org.id,
      project_key: `proj-${key}`,
      name: `Project ${key.toUpperCase()}`,
    })
    .returning('id')
    .executeTakeFirstOrThrow();
  await adminDb
    .insertInto('memberships')
    .values({
      organization_id: org.id,
      user_id: user.id,
      role: 'ORGANIZATION_OWNER',
    })
    .execute();
  const workflow = await adminDb
    .insertInto('workflows')
    .values({
      organization_id: org.id,
      project_id: project.id,
      workflow_type: 'FEATURE_DELIVERY',
      title: `Workflow ${key.toUpperCase()}`,
      created_by: user.id,
    })
    .returning('id')
    .executeTakeFirstOrThrow();
  return {
    organizationId: asOrganizationId(org.id),
    userId: asUserId(user.id),
    projectId: project.id,
    workflowId: workflow.id,
  };
}

/** Two organizations, each with a user (org owner), a project and a workflow. Seeded as the owner role. */
export async function seedTwoTenants(adminDb: Db): Promise<SeededTenants> {
  return {
    a: await seedTenant(adminDb, 'a'),
    b: await seedTenant(adminDb, 'b'),
  };
}
