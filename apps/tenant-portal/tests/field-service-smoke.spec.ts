/**
 * Field Service V1 — E2E contra tenant real Volt Serveis (seed field_service).
 * Acme es queda sense sector (onboarding / gating).
 */
import { expect, test } from '@playwright/test'
import { AUTH_STATE_PATH, EHR_FIXTURES } from './e2e-users'

const VOLT_TENANT_ID = EHR_FIXTURES.voltTenantId
const VOLT_ORDER_NAME = /Canvi d'endolls/i

async function pinVoltTenant(page: import('@playwright/test').Page) {
  await page.addInitScript((id: string) => {
    sessionStorage.setItem('selectedTenantId', id)
  }, VOLT_TENANT_ID)

  await page.goto('/dashboard')
  await expect(page).toHaveURL(/\/field\/today/, { timeout: 25_000 })

  const tenantSelector = page.getByLabel('Selecciona organització')
  if ((await tenantSelector.count()) > 0) {
    await expect(tenantSelector).toHaveValue(VOLT_TENANT_ID, { timeout: 15_000 })
  } else {
    await expect(page.locator('aside').getByText('Volt Serveis', { exact: true })).toBeVisible({
      timeout: 15_000,
    })
  }
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

  test('Volt: dashboard → Avui with today order', async ({ page }) => {
    await pinVoltTenant(page)

    await expect(page.getByRole('heading', { name: /Avui/i })).toBeVisible()
    await expect(page.getByRole('link', { name: /Avui/i }).first()).toBeVisible()
    await expect(page.getByRole('link', { name: /Ordres/i }).first()).toBeVisible()
    await expect(page.getByRole('link', { name: /Agenda/i }).first()).toBeVisible()
    await expect(page.getByRole('link', { name: /Més/i }).first()).toBeVisible()

    await expect(page.getByText(VOLT_ORDER_NAME).first()).toBeVisible({ timeout: 20_000 })
    await expect(page.getByText(/Constructora Meridian/i).first()).toBeVisible()
  })

  test('Volt: open order → checklist + start visit', async ({ page, context }) => {
    await context.grantPermissions(['geolocation'])
    await context.setGeolocation({ latitude: 41.392, longitude: 2.152 })

    await pinVoltTenant(page)

    await page.getByText(VOLT_ORDER_NAME).first().click()
    await expect(page).toHaveURL(/\/field\/orders\/51000000-0000-0000-0000-000000000101/)

    await expect(
      page.getByRole('heading', { name: VOLT_ORDER_NAME }).or(page.getByText(VOLT_ORDER_NAME).first()),
    ).toBeVisible({ timeout: 15_000 })

    await expect(page.getByText(/Checklist de visita/i)).toBeVisible()
    await expect(
      page.getByRole('button', { name: /Afegir checklist|Canviar plantilla|Aplicar plantilla/i }).first(),
    ).toBeVisible({ timeout: 15_000 })
    await expect(page.getByRole('button', { name: /Tancar visita/i })).toBeVisible()

    await page.goto('/field/today')
    await expect(page.getByRole('heading', { name: /Avui/i })).toBeVisible()

    const startBtn = page.getByRole('button', { name: /Iniciar visita/i })
    await expect(startBtn).toBeVisible()
    await startBtn.click()
    await expect(startBtn).toBeDisabled({ timeout: 20_000 })
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
    await expect(page.getByRole('link', { name: /Clients?/i }).first()).toBeVisible()
  })
})
