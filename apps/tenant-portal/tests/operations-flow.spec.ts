/**
 * E2E UI — /settings/operations (tenant_operation_logs)
 *
 * Requereix Supabase local amb seed + migració tenant_operation_logs.
 * Abans del test UI, insereix una incidència via service_role (RPC).
 *
 * Variables d'entorn (opcional):
 *   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, E2E_PASSWORD
 */
import { expect, test } from '@playwright/test'
import { AUTH_STATE_PATH, E2E_USERS } from './e2e-users'

const SUPABASE_URL = process.env.SUPABASE_URL ?? process.env.VITE_SUPABASE_URL ?? 'http://127.0.0.1:54321'
let SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? ''
const ANON_KEY =
  process.env.VITE_SUPABASE_PUBLISHABLE_DEFAULT_KEY ??
  'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH'

async function loadLocalServiceKey(): Promise<void> {
  if (SERVICE_KEY) return
  try {
    const { execSync } = await import('node:child_process')
    const { fileURLToPath } = await import('node:url')
    const { dirname, join } = await import('node:path')
    const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
    const raw = execSync('supabase status -o json', {
      cwd: root,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    })
    const status = JSON.parse(raw) as { SERVICE_ROLE_KEY?: string; SECRET_KEY?: string }
    SERVICE_KEY = status.SERVICE_ROLE_KEY ?? status.SECRET_KEY ?? ''
  } catch {
    // validated in beforeAll
  }
}

const ACME_TENANT_ID = '10000000-0000-0000-0000-000000000001'

let correlationId = ''
let logId: string | null = null
let testTitle = ''

async function seedOperationLog(): Promise<void> {
  if (!SERVICE_KEY) {
    throw new Error('SUPABASE_SERVICE_ROLE_KEY no configurada — salta seed E2E')
  }

  correlationId = `e2e-ui-ops-${Date.now()}`
  testTitle = `E2E UI: fallada email ${correlationId.slice(-6)}`

  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/log_tenant_operation`, {
    method: 'POST',
    headers: {
      apikey: ANON_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      p_tenant_id: ACME_TENANT_ID,
      p_integration_type: 'email',
      p_operation_code: 'send_transactional_email',
      p_status: 'failed',
      p_title: testTitle,
      p_message: 'Simulació E2E per Playwright',
      p_error_code: 'provider_error',
      p_correlation_id: correlationId,
      p_external_service: 'resend',
      p_is_retryable: true,
      p_payload_summary: { e2e: true },
    }),
  })

  if (!res.ok) {
    const text = await res.text()
    throw new Error(`Seed log_tenant_operation failed: ${res.status} ${text.slice(0, 200)}`)
  }
  logId = (await res.json()) as string
}

async function deleteOperationLog(): Promise<void> {
  if (!logId || !SERVICE_KEY) return
  await fetch(`${SUPABASE_URL}/rest/v1/tenant_operation_logs?id=eq.${logId}`, {
    method: 'DELETE',
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      'Accept-Profile': 'api',
    },
  }).catch(() => undefined)
}

async function mockOnboardingCompleted(page: import('@playwright/test').Page) {
  await page.route('**/rest/v1/my_tenant*', async (route) => {
    const response = await route.fetch()
    const tenants = (await response.json()) as Array<Record<string, unknown>>
    await route.fulfill({
      response,
      json: tenants.map((tenant) => ({
        ...tenant,
        sector_profile_id: tenant.sector_profile_id ?? '40000000-0000-0000-0000-000000000001',
        archetype: tenant.archetype ?? 'field_service',
        sector_icon: tenant.sector_icon ?? '🔧',
        sector_display_name: tenant.sector_display_name ?? 'Serveis al Camp',
      })),
    })
  })
}

test.describe('Operations flow', () => {
  // Bob: owner únic d'Acme (evita confusions multi-tenant d'Alice amb Beta).
  test.use({ storageState: AUTH_STATE_PATH.bob })
  test.describe.configure({ timeout: 60_000 })

  test.beforeAll(async () => {
    await loadLocalServiceKey()
    if (!SERVICE_KEY) {
      test.skip(true, 'Supabase local no disponible o sense service role key')
      return
    }
    await seedOperationLog()
  })

  test.afterAll(async () => {
    await deleteOperationLog()
  })

  test.beforeEach(async ({ page }) => {
    await page.unrouteAll({ behavior: 'ignoreErrors' })
    await mockOnboardingCompleted(page)
  })

  test('dashboard banner shows unresolved operations since last visit', async ({ page }) => {
    test.skip(!SERVICE_KEY, 'SUPABASE_SERVICE_ROLE_KEY required for seed')

    await page.addInitScript(() => {
      for (const key of Object.keys(localStorage)) {
        if (key.startsWith('operationsLastDashboardAt_')) localStorage.removeItem(key)
      }
    })

    await page.goto('/dashboard')
    await expect(page).toHaveURL(/\/dashboard/, { timeout: 20_000 })

    const banner = page.getByRole('alert').filter({ hasText: /Incidències d'operacions|operacions han fallat/i })
    await expect(banner).toBeVisible({ timeout: 15_000 })
    await expect(banner.getByRole('link', { name: /historial d'operacions/i })).toBeVisible()
  })

  test('settings tab badge and operations page resolve flow', async ({ page }) => {
    test.skip(!SERVICE_KEY, 'SUPABASE_SERVICE_ROLE_KEY required for seed')

    const countRpc = page.waitForResponse(
      (res) =>
        res.url().includes('/rpc/get_unresolved_operation_count') &&
        res.request().method() === 'POST',
      { timeout: 30_000 },
    )

    await page.goto('/settings/config')
    await expect(page).toHaveURL(/\/settings\/config/, { timeout: 20_000 })

    const rpcRes = await countRpc
    expect(rpcRes.ok()).toBeTruthy()
    expect(Number(await rpcRes.json())).toBeGreaterThan(0)

    const operationsTab = page.getByRole('link', { name: /Operacions/i })
    await expect(operationsTab).toBeVisible({ timeout: 15_000 })
    await expect(operationsTab.locator('span.rounded-full')).toBeVisible({ timeout: 15_000 })

    await page.goto('/settings/operations')
    await expect(page).toHaveURL(/\/settings\/operations/)

    await expect(page.getByRole('heading', { name: /Historial d'operacions/i })).toBeVisible()

    const row = page.getByText(testTitle)
    await expect(row).toBeVisible({ timeout: 15_000 })

    await page.getByRole('button', { name: /Marcar com a revisat/i }).first().click()

    await expect(page.getByText(/Revisat:/i).first()).toBeVisible({ timeout: 15_000 })
  })
})

test.describe('Operations access control', () => {
  test.use({
    storageState: { cookies: [], origins: [] },
  })

  test('member role does not see operations tab', async ({ page }) => {
    await page.unrouteAll({ behavior: 'ignoreErrors' })
    await mockOnboardingCompleted(page)

    await page.goto('/login')
    await expect(page.locator('#email')).toBeVisible({ timeout: 20_000 })
    await page.locator('#email').fill('dave@acme-corp.com')
    await page.locator('#password').fill(E2E_USERS.alice.password)
    await page.locator('form button[type="submit"]').first().click()
    await expect(page).not.toHaveURL(/\/login$/, { timeout: 20_000 })

    await page.goto('/settings/config')
    await expect(page.getByRole('link', { name: /^Operacions$/i })).toHaveCount(0)
  })
})
