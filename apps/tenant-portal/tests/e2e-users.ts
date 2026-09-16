export type E2EUserKey =
  | 'alice'
  | 'bob'
  | 'carol'
  | 'charlie'
  | 'dave'
  | 'gina'
  | 'hector'
  | 'ines'

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
  gina: {
    key: 'gina',
    email: process.env.E2E_GINA_EMAIL ?? 'gina@riera-instal.com',
    password: process.env.E2E_GINA_PASSWORD ?? sharedPassword,
  },
  hector: {
    key: 'hector',
    email: process.env.E2E_HECTOR_EMAIL ?? 'hector@riera-instal.com',
    password: process.env.E2E_HECTOR_PASSWORD ?? sharedPassword,
  },
  ines: {
    key: 'ines',
    email: process.env.E2E_INES_EMAIL ?? 'ines@riera-instal.com',
    password: process.env.E2E_INES_PASSWORD ?? sharedPassword,
  },
}

export const AUTH_STATE_PATH: Record<E2EUserKey, string> = {
  alice: 'playwright/.auth/alice.json',
  bob: 'playwright/.auth/bob.json',
  carol: 'playwright/.auth/carol.json',
  charlie: 'playwright/.auth/charlie.json',
  dave: 'playwright/.auth/dave.json',
  gina: 'playwright/.auth/gina.json',
  hector: 'playwright/.auth/hector.json',
  ines: 'playwright/.auth/ines.json',
}

/** Fixture UUIDs from supabase/seeds/smoke_ehr_employees_fixtures.sql */
export const EHR_FIXTURES = {
  acmeTenantId: '10000000-0000-0000-0000-000000000001',
  betaTenantId: '10000000-0000-0000-0000-000000000002',
  /** Volt Serveis — seed field_service autònom (Alice owner) */
  voltTenantId: '10000000-0000-0000-0000-000000000003',
  /** Riera Instal·lacions — seed field_service PIME (Gina oficina, Hèctor/Inés tècnics) */
  rieraTenantId: '10000000-0000-0000-0000-000000000004',
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
