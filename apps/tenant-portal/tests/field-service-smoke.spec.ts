/**
 * Field Service V1 — E2E contra tenant real Volt Serveis (seed field_service).
 * Acme es queda sense sector (onboarding / gating).
 */
import { expect, test } from '@playwright/test'
import { AUTH_STATE_PATH, EHR_FIXTURES } from './e2e-users'

const VOLT_TENANT_ID = EHR_FIXTURES.voltTenantId
const VOLT_ORDER_NAME = /Canvi d'endolls/i
const COMPLETED_ORDER_ID = '51000000-0000-0000-0000-000000000101'
const PILOT_ORDER_ID = '307df31d-1d46-48e9-8532-f4e5dc4c458a'

async function pinVoltTenant(page: import('@playwright/test').Page) {
  await page.addInitScript((id: string) => {
    sessionStorage.setItem('selectedTenantId', id)
  }, VOLT_TENANT_ID)

  await page.goto('/field/today')
  await expect(page).toHaveURL(/\/field\/today/, { timeout: 25_000 })

  const tenantSelector = page.getByLabel('Selecciona organització')
  await expect(tenantSelector).toHaveValue(VOLT_TENANT_ID, { timeout: 15_000 })
}

async function pinAcmeTenant(page: import('@playwright/test').Page) {
  await page.addInitScript((id: string) => {
    sessionStorage.setItem('selectedTenantId', id)
  }, EHR_FIXTURES.acmeTenantId)

  await page.goto('/dashboard')
  await expect(page.getByRole('heading', { name: 'Notes' })).toBeVisible({ timeout: 25_000 })
}

test.describe('Field Service smoke', () => {
  test.use({ storageState: AUTH_STATE_PATH.alice })

  test('Volt owner desktop: dashboard stays office home', async ({ page }) => {
    await page.addInitScript((id: string) => {
      sessionStorage.setItem('selectedTenantId', id)
    }, VOLT_TENANT_ID)

    await page.goto('/dashboard')
    await expect(page).toHaveURL(/\/dashboard/, { timeout: 25_000 })
    await expect(page.getByLabel('Selecciona organització')).toHaveValue(VOLT_TENANT_ID, {
      timeout: 15_000,
    })
    await expect(page.getByText(/Pantalla d'inici|Pantalla de inicio|Home screen/i)).toHaveCount(0)
    await page.goto('/settings/config')
    await expect(page.getByText(/Aparença i inici|Appearance and home/i)).toBeVisible()
    await expect(page.getByText(/Pantalla d'inici|Pantalla de inicio|Home screen/i)).toBeVisible()
  })

  test('Volt: Avui with today order', async ({ page }) => {
    await pinVoltTenant(page)

    await expect(page.getByRole('heading', { name: /Avui/i })).toBeVisible()
    await expect(page.getByRole('link', { name: /Avui/i }).first()).toBeVisible()
    await expect(page.getByRole('link', { name: /Ordres/i }).first()).toBeVisible()
    await expect(page.getByRole('link', { name: /Agenda/i }).first()).toBeVisible()
    await expect(page.getByRole('link', { name: /Més/i }).first()).toBeVisible()

    await expect(page.getByText(VOLT_ORDER_NAME).first()).toBeVisible({ timeout: 20_000 })
    await expect(page.getByText(/Constructora Meridian/i).first()).toBeVisible()
  })

  test('Volt: open order → canonical phases + start visit', async ({ page, context }) => {
    await context.grantPermissions(['geolocation'])
    await context.setGeolocation({ latitude: 41.392, longitude: 2.152 })

    await pinVoltTenant(page)

    await page.getByText(VOLT_ORDER_NAME).first().click()
    await expect(page).toHaveURL(new RegExp(`/field/orders/${COMPLETED_ORDER_ID}`))

    await expect(
      page.getByRole('heading', { name: VOLT_ORDER_NAME }).or(page.getByText(VOLT_ORDER_NAME).first()),
    ).toBeVisible({ timeout: 15_000 })

    await page.getByRole('tab', { name: /Fer/i }).click()
    await expect(page).toHaveURL(new RegExp(`${COMPLETED_ORDER_ID}\\?tab=do`))
    await expect(page.getByRole('tab', { name: /Fer/i })).toHaveAttribute(
      'data-state',
      'active',
    )

    await page.getByRole('tab', { name: /Entregar/i }).click()
    await expect(page).toHaveURL(new RegExp(`${COMPLETED_ORDER_ID}\\?tab=deliver`))
    await expect(
      page.getByRole('heading', { name: 'Albarà i cobrament' }),
    ).toBeVisible()
    await expect(
      page.getByRole('button', { name: /Part de treball.*Opcional/i }),
    ).toBeVisible()
    await expect(
      page.getByRole('heading', { name: /Part de treball \(butlletí\)/i }),
    ).toHaveCount(0)

    await page.goto('/field/today')
    await expect(page.getByRole('heading', { name: /Avui/i })).toBeVisible()

    const startBtn = page.getByRole('button', { name: /Iniciar visita/i })
    await expect(startBtn).toBeVisible()
    await startBtn.click()
    await expect(startBtn).toBeDisabled({ timeout: 20_000 })
  })

  test('Volt: two reported OS cases keep progress and expose quote state', async ({ page }) => {
    await pinVoltTenant(page)

    await page.goto(`/field/orders/${PILOT_ORDER_ID}?tab=do`)
    await expect(page).toHaveURL(new RegExp(`${PILOT_ORDER_ID}\\?tab=do`))
    await expect(page.getByRole('tablist')).toHaveCount(1)
    await expect(
      page.getByRole('button', { name: /Reprendre feina|Aturar|Temps en curs/i }).first(),
    ).toBeVisible({ timeout: 15_000 })

    await page.goto(`/field/orders/${COMPLETED_ORDER_ID}?tab=prepare`)
    await expect(page.getByText(/Refusat/i).first()).toBeVisible({ timeout: 15_000 })
    const createQuote = page.getByRole('button', { name: /Crear nou pressupost/i })
    if (await createQuote.count()) {
      await expect(createQuote).toBeVisible()
      await expect(createQuote).not.toHaveCSS('position', 'fixed')
    }

    await page.getByRole('tab', { name: /Entregar/i }).click()
    await expect(
      page.getByRole('heading', { name: 'Albarà i cobrament' }),
    ).toBeVisible()
    await page
      .getByRole('button', { name: /Part de treball.*Opcional/i })
      .click()
    await expect(
      page.getByRole('heading', { name: /Part de treball \(butlletí\)/i }),
    ).toBeVisible()
    await expect(
      page.getByRole('heading', { name: 'Albarà i cobrament' }),
    ).toHaveCount(0)
    const primaryAction = page
      .getByRole('button', {
        name: /Crear nou pressupost|Mostrar pressupost|Revisar i tancar|Mostrar albarà|Cobrar|Enviar comprovant/i,
      })
      .first()
    if (await primaryAction.count()) {
      await expect(primaryAction).not.toHaveCSS('position', 'fixed')
    }
    const dossier = page.getByText('Expedient tancat', { exact: true })
    if (await dossier.count()) {
      await dossier.scrollIntoViewIfNeeded()
      await expect(dossier).toBeVisible()
    }
  })

  test('Volt: checklist templates page loads with platform library', async ({ page }) => {
    await pinVoltTenant(page)
    await page.goto('/field/checklist-templates')
    await expect(page.getByRole('heading', { name: /Plantilles de checklist/i })).toBeVisible({
      timeout: 15_000,
    })
    await expect(page.getByText(/Biblioteca|Plataforma|Clonar/i).first()).toBeVisible({
      timeout: 15_000,
    })
  })

  test('Volt: maintenance plans page loads', async ({ page }) => {
    await pinVoltTenant(page)
    await page.goto('/field/maintenance-plans')
    await expect(page.getByRole('heading', { name: /Plans de manteniment/i })).toBeVisible({
      timeout: 15_000,
    })
  })

  test('Volt: orders list uses sector vocabulary', async ({ page }) => {
    // Sense overlay de tenant: el heading és el plural del seed (Ordres de servei).
    await pinVoltTenant(page)

    await page.goto('/field/orders')
    await expect(page).toHaveURL(/\/field\/orders/)
    await expect(
      page.getByRole('heading', { name: /Ordres de servei|Ordre de servei/i }),
    ).toBeVisible({ timeout: 15_000 })
    await expect(page.getByText(VOLT_ORDER_NAME).first()).toBeVisible()
  })

  test('Volt: other modules still reachable (plan allows)', async ({ page }) => {
    await pinVoltTenant(page)

    // Archetype no amaga mòduls del pla: Catàleg / Empleats al sidebar
    await expect(page.getByRole('link', { name: /Empleats/i }).first()).toBeVisible()
    await expect(page.getByRole('link', { name: /Catàleg/i }).first()).toBeVisible()

    await page.goto('/catalog')
    await expect(page).toHaveURL(/\/catalog/)
    await expect(page.getByRole('heading', { name: /Catàleg/i })).toBeVisible({ timeout: 15_000 })
    await expect(page.getByText(/Visita tècnica|Hora de treball/i).first()).toBeVisible({
      timeout: 15_000,
    })
  })

  test('Acme (no FS) cannot use field shell', async ({ page }) => {
    await pinAcmeTenant(page)

    await page.goto('/field/today')
    await expect(page).toHaveURL(/\/dashboard/)
  })

  test('Volt: more page links to clients', async ({ page }) => {
    await pinVoltTenant(page)

    await page.goto('/field/more')
    await expect(page.getByText(/Eines de camp/i)).toBeVisible()
    await expect(page.getByText(/Accessos ràpids/i)).toBeVisible()
    await expect(page.getByRole('link', { name: /Clients?/i }).first()).toBeVisible()
    await expect(page.locator('main').getByRole('link', { name: /Fitxatge|Horari/i })).toHaveCount(0)
  })
})

test.describe('Field Service mobile attendance navigation', () => {
  test.use({ storageState: AUTH_STATE_PATH.hector })

  test.beforeEach(async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 })
    await page.addInitScript((id: string) => {
      sessionStorage.setItem('selectedTenantId', id)
    }, EHR_FIXTURES.rieraTenantId)
  })

  test('member keeps bottom navigation on Today and Hours', async ({ page }) => {
    await page.goto('/field/today')
    const fieldNav = page.getByRole('navigation', { name: /Camp|Campo|Field/i })
    await expect(fieldNav).toBeVisible({ timeout: 20_000 })
    await expect(fieldNav.getByRole('link', { name: /Horari|Horario|Hours/i })).toBeVisible()
    await expect(page.getByText(/Jornada d'avui|Pròxima jornada/i)).toBeVisible()

    await page.goto('/attendance')
    await expect(fieldNav).toBeVisible()
    await expect(page.getByRole('navigation', { name: /Horari personal/i })).toBeVisible()
    await expect(page.getByRole('link', { name: /Fitxar/i })).toBeVisible()
    await expect(page.getByRole('link', { name: /Calendari/i })).toBeVisible()
    await expect(page.getByRole('link', { name: /Absències/i })).toBeVisible()
  })

  test('member More has field preferences and no sidebar duplicates', async ({ page }) => {
    await page.goto('/field/more')
    await expect(page.getByText(/Eines de camp/i)).toBeVisible({ timeout: 20_000 })
    await expect(page.getByText(/Accessos ràpids/i)).toBeVisible()
    await expect(page.getByRole('link', { name: /Clients?/i })).toBeVisible()
    await expect(page.getByRole('link', { name: /Pressupostos|Catàleg|Configuració/i })).toHaveCount(0)
    await expect(page.locator('main').getByRole('link', { name: /Fitxatge|Horari/i })).toHaveCount(0)
  })
})

test.describe('Field Service owner mobile dashboard navigation', () => {
  test.use({ storageState: AUTH_STATE_PATH.gina })

  test('dashboard keeps the field bottom navigation', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 })
    await page.addInitScript((id: string) => {
      sessionStorage.setItem('selectedTenantId', id)
    }, EHR_FIXTURES.rieraTenantId)
    await page.goto('/settings/config')
    const homePreference = page.locator('select').filter({
      has: page.locator('option', { hasText: /Sempre Inici|Siempre Inicio|Always Home/i }),
    })
    await expect(homePreference).toBeVisible({ timeout: 20_000 })
    await homePreference.selectOption('dashboard')
    await page.goto('/dashboard')
    await expect(page).toHaveURL(/\/dashboard/, { timeout: 20_000 })
    await expect(
      page.getByRole('navigation', { name: /Camp|Campo|Field/i }),
    ).toBeVisible()
  })
})
