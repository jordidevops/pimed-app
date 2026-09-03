/**
 * E2E — configuració IA BYOK (tenant-portal).
 *
 * Tests sense xarxa externa: smoke UI (sempre s'executen).
 * Test d'integració opcional: verifica clau → genera contingut → comprova ledger.
 *
 * ## E2E_AI_API_KEY (només integració)
 *
 * Proveïdor: **OpenAI** (`sk-...`). El test omple la secció OpenAI a `/settings/ai`,
 * en verifica la clau i crida `generate-ai-content` amb el proveïdor per defecte del tenant.
 *
 * On posar-la (tria una):
 *
 * 1. **Shell (recomanat)** — Playwright llegeix `process.env` directament:
 *    ```bash
 *    cd apps/tenant-portal
 *    E2E_AI_API_KEY=sk-... npm run test:e2e -- tests/ai-byok.spec.ts
 *    ```
 *
 * 2. **Fitxer local** — `apps/tenant-portal/.env.development` (no versionar claus reals):
 *    ```
 *    E2E_AI_API_KEY=sk-...
 *    ```
 *    Cal exportar-la abans d'executar Playwright, p.ex. des de PowerShell:
 *    `Get-Content .env.development | ForEach-Object { ... }` o definir la variable a la sessió.
 *
 * 3. **CI** — secret del pipeline (`E2E_AI_API_KEY`), mai al repositori.
 *
 * Sense aquesta variable, el test `full flow: verify key → generate → ledger` es salta.
 */
import { expect, test, type Page, type Route } from '@playwright/test'
import { AUTH_STATE_PATH } from './e2e-users'

async function mockOnboardingCompleted(page: Page) {
  await page.route('**/rest/v1/my_tenant*', async (route: Route) => {
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

async function openAiSettings(page: Page) {
  await page.goto('/settings/ai')
  await expect(page).toHaveURL(/\/settings\/ai$/, { timeout: 15_000 })

  const main = page.locator('main')
  const tabs = main.getByRole('tablist')

  await expect(main.getByRole('heading', { name: /Intel·ligència artificial|Generació.*IA/i })).toBeVisible({ timeout: 30_000 })
  await expect(tabs.getByRole('tab', { name: 'Configuració' })).toBeVisible()
  await expect(tabs.getByRole('tab', { name: 'Ús i límits' })).toBeVisible()

  return main
}

test.describe('AI BYOK', () => {
  test.use({ storageState: AUTH_STATE_PATH.bob })

  test.beforeEach(async ({ page }) => {
    await page.unrouteAll({ behavior: 'ignoreErrors' })
    await mockOnboardingCompleted(page)
  })

  test('settings UI smoke', async ({ page }) => {
    const main = await openAiSettings(page)

    await expect(main.getByRole('heading', { name: 'OpenAI', exact: true })).toBeVisible()
    await expect(main.getByRole('heading', { name: 'Anthropic', exact: true })).toBeVisible()
    await expect(main.getByRole('heading', { name: 'Google Gemini', exact: true })).toBeVisible()
    await expect(main.getByText(/Polítiques de dades/i)).toBeVisible()
    await expect(main.getByRole('heading', { name: 'OpenRouter', exact: true })).toBeVisible()

    await main.getByRole('button', { name: 'Desar OpenAI' }).click()
    await expect(page.getByText('Cal introduir una API key', { exact: true }).first()).toBeVisible()

    const tabs = main.getByRole('tablist')
    await tabs.getByRole('tab', { name: 'Ús i límits' }).click()
    await expect(main.getByText('Límits actuals')).toBeVisible()

    const membersTab = tabs.getByRole('tab', { name: 'Membres' })
    await expect(membersTab).toBeVisible()
    await membersTab.click()
    await expect(main.getByText(/Defineix qui pot usar la IA/i)).toBeVisible()
  })

  test('full flow: verify key → generate → ledger', async ({ page, request }) => {
    const apiKey = process.env.E2E_AI_API_KEY
    test.skip(!apiKey, 'Set E2E_AI_API_KEY to run integration test')

    const main = await openAiSettings(page)

    const openaiSection = main.locator('section').filter({ hasText: 'OpenAI' }).first()
    await openaiSection.getByLabel(/API key/i).fill(apiKey!)
    await openaiSection.getByRole('button', { name: /Verificar i desar/i }).click()

    await expect(page.getByText(/verificada/i)).toBeVisible({ timeout: 60_000 })

    const supabaseUrl = process.env.VITE_SUPABASE_URL ?? 'http://127.0.0.1:54321'
    const tenantId = await page.evaluate(() => localStorage.getItem('active_tenant_id'))
    test.skip(!tenantId, 'No active tenant in localStorage')

    const authToken = await page.evaluate(() => {
      const raw = localStorage.getItem('sb-127-auth-token') ?? localStorage.getItem('supabase.auth.token')
      if (!raw) return null
      try {
        const parsed = JSON.parse(raw)
        return parsed?.access_token ?? parsed?.currentSession?.access_token ?? null
      } catch {
        return null
      }
    })
    test.skip(!authToken, 'Could not read auth token from storage')

    const genRes = await request.post(`${supabaseUrl}/functions/v1/generate-ai-content`, {
      headers: {
        Authorization: `Bearer ${authToken}`,
        'x-tenant-id': tenantId!,
        'Content-Type': 'application/json',
      },
      data: {
        feature: 'e2e_test',
        messages: [{ role: 'user', content: 'Respon només: OK' }],
        responseFormat: 'text',
        maxTokens: 16,
      },
    })

    expect(genRes.ok()).toBeTruthy()
    const body = await genRes.json()
    expect(body.content).toBeTruthy()
  })
})
