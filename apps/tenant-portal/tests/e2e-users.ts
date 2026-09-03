export type E2EUserKey = 'alice' | 'bob' | 'carol' | 'charlie' | 'dave'

export interface E2EUser {
  key: E2EUserKey
  email: string
  password: string
}

const sharedPassword = process.env.E2E_PASSWORD ?? 'Test1234!'

export const E2E_USERS: Record<E2EUserKey, E2EUser> = {
  alice: {
    key: 'alice',
    email: process.env.E2E_ALICE_EMAIL ?? 'alice@acme-corp.com',
    password: process.env.E2E_ALICE_PASSWORD ?? sharedPassword,
  },
  bob: {
    key: 'bob',
    email: process.env.E2E_BOB_EMAIL ?? 'bob@acme-corp.com',
    password: process.env.E2E_BOB_PASSWORD ?? sharedPassword,
  },
  carol: {
    key: 'carol',
    // Local seed does not include owner@beta-startup.com; fallback to Alice.
    email: process.env.E2E_CAROL_EMAIL ?? 'alice@acme-corp.com',
    password: process.env.E2E_CAROL_PASSWORD ?? sharedPassword,
  },
  charlie: {
    key: 'charlie',
    email: process.env.E2E_CHARLIE_EMAIL ?? 'charlie@acme-corp.com',
    password: process.env.E2E_CHARLIE_PASSWORD ?? sharedPassword,
  },
  dave: {
    key: 'dave',
    email: process.env.E2E_DAVE_EMAIL ?? 'dave@acme-corp.com',
    password: process.env.E2E_DAVE_PASSWORD ?? sharedPassword,
  },
}

export const AUTH_STATE_PATH: Record<E2EUserKey, string> = {
  alice: 'playwright/.auth/alice.json',
  bob: 'playwright/.auth/bob.json',
  carol: 'playwright/.auth/carol.json',
  charlie: 'playwright/.auth/charlie.json',
  dave: 'playwright/.auth/dave.json',
}

/** Fixture UUIDs from supabase/seeds/smoke_ehr_employees_fixtures.sql */
export const EHR_FIXTURES = {
  acmeTenantId: '10000000-0000-0000-0000-000000000001',
  betaTenantId: '10000000-0000-0000-0000-000000000002',
  /** Volt Serveis — seed field_service (Alice owner) */
  voltTenantId: '10000000-0000-0000-0000-000000000003',
  aliceEmployeeId: '40000000-0000-0000-0000-000000000001',
  qaSmokeEmployeeId: 'e1000000-0000-0000-0000-000000000001',
  qaOffboardEmployeeId: 'e1000000-0000-0000-0000-000000000002',
  qaBetaEmployeeId: 'e1000000-0000-0000-0000-000000000003',
  qaSmokeName: 'QA Smoke Employee',
  qaBetaName: 'QA Beta Employee',
  qaSmokeEmail: 'qa-smoke@acme-corp.example',
  medicalCertName: 'Reconeixement mèdic aptitud',
  heightCertName: 'Treball en alçada',
} as const
