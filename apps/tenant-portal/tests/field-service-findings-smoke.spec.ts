/**
 * Field Service — smoke de troballes / disposició / OS de reparació.
 * Flux: crear OS → plantilla review → fail + diferit → reparació → tancar inspecció.
 */
import { expect, test, type Page } from '@playwright/test'
import { AUTH_STATE_PATH, EHR_FIXTURES } from './e2e-users'

const VOLT_TENANT_ID = EHR_FIXTURES.voltTenantId
const REVIEW_TEMPLATE = /Revisió bàsica \(Review\)/i

async function pinVoltTenant(page: Page) {
  await page.addInitScript((id: string) => {
    sessionStorage.setItem('selectedTenantId', id)
  }, VOLT_TENANT_ID)

  await page.goto('/field/today')
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

async function createVoltOrder(page: Page, name: string): Promise<string> {
  await page.goto('/field/orders')
  await expect(page.getByRole('heading', { name: /Ordres de servei|Ordre de servei/i })).toBeVisible({
    timeout: 15_000,
  })

  await page.getByRole('button', { name: /Nova ordre/i }).first().click()
  await expect(page.getByRole('heading', { name: /Nova ordre/i })).toBeVisible()

  await page.locator('#project-name').fill(name)
  await page.locator('#project-type').selectOption('work_order')
  await page.locator('#project-status').selectOption('active')
  await page.locator('#project-client').selectOption({ label: 'Constructora Meridian S.L.' })
  await expect(page.locator('#project-contact-site')).toBeEnabled({ timeout: 10_000 })
  await page.locator('#project-contact-site').selectOption({ index: 1 })

  await page.getByRole('button', { name: /^Desar$/i }).click()
  await expect(page).toHaveURL(/\/field\/orders\/[0-9a-f-]{36}/, { timeout: 20_000 })
  await expect(page.getByRole('heading', { name })).toBeVisible({ timeout: 15_000 })

  const match = page.url().match(/\/field\/orders\/([0-9a-f-]{36})/i)
  if (!match?.[1]) throw new Error('No s\'ha pogut llegir l\'id de l\'ordre creada')
  return match[1]
}

function itemBlock(page: Page, title: RegExp) {
  // RunItemInput root for single_choice items
  return page
    .locator('div.space-y-2.px-1')
    .filter({ has: page.locator('p.text-sm.font-medium', { hasText: title }) })
    .first()
}

test.describe('Field Service findings smoke', () => {
  test.describe.configure({ timeout: 120_000 })
  test.use({ storageState: AUTH_STATE_PATH.alice })

  test('inspecció: fail → diferit → reparació → completar origen', async ({ page }) => {
    await pinVoltTenant(page)

    const orderName = `Smoke findings ${Date.now()}`
    const sourceId = await createVoltOrder(page, orderName)

    // Intent inspecció (copy + botó Generar reparació)
    await page.getByRole('combobox').filter({ hasText: /Genèrica|Inspecció|Correctiva/i }).click()
    await page.getByRole('option', { name: /^Inspecció$/i }).click()
    await expect(page.getByRole('combobox').filter({ hasText: /Inspecció/i })).toBeVisible({
      timeout: 10_000,
    })

    // Aplicar plantilla review amb semàfor (fail = Urgent)
    await page.getByRole('button', { name: /Afegir checklist/i }).click()
    const dialog = page.getByRole('dialog')
    await expect(dialog.getByRole('heading', { name: /Afegir checklist/i })).toBeVisible()
    await dialog.getByText(REVIEW_TEMPLATE).click()
    await dialog.getByRole('button', { name: /^Aplicar/i }).click()
    await expect(dialog).toBeHidden({ timeout: 20_000 })
    await expect(page.getByText(/Revisió bàsica/i).first()).toBeVisible({ timeout: 15_000 })

    const itemA = itemBlock(page, /Estat general de la instal·lació/i)
    const itemB = itemBlock(page, /Seguretat elèctrica/i)

    // Patch parcial: nota no ha d'esborrar l'opció
    await itemA.getByRole('button', { name: /^Correcte$/i }).click()
    const answerNote = itemA.getByPlaceholder(/^Nota$/i)
    await answerNote.fill('nota-parcial-smoke')
    await answerNote.blur()
    await expect(itemA.getByRole('button', { name: /^Correcte$/i })).toHaveClass(/bg-emerald/, {
      timeout: 10_000,
    })
    await expect(itemA.getByText(/Disposició de la troballa/i)).toHaveCount(0)

    // Fail + nota obligatòria + diferit → tasca
    await itemA.getByRole('button', { name: /^Urgent$/i }).click()
    await expect(itemA.getByText(/Disposició de la troballa/i)).toBeVisible({ timeout: 10_000 })
    await answerNote.fill('Fuga visible; cal reparació')
    await answerNote.blur()
    await itemA.getByRole('button', { name: /Pendent \/ diferit/i }).click()
    await expect(itemA.getByText(/Tasca de seguiment/i)).toBeVisible({ timeout: 15_000 })

    // Segon ítem required → pass
    await itemB.getByRole('button', { name: /^Correcte$/i }).click()
    await expect(itemB.getByRole('button', { name: /^Correcte$/i })).toHaveClass(/bg-emerald/, {
      timeout: 10_000,
    })

    // Generar OS de reparació (navega a la filla)
    await page.getByRole('button', { name: /Generar reparació/i }).click()
    await expect(page).toHaveURL(new RegExp(`/field/orders/(?!${sourceId})[0-9a-f-]{36}`), {
      timeout: 25_000,
    })
    await expect(page.getByRole('link', { name: /Obrir visita origen/i })).toBeVisible({
      timeout: 15_000,
    })

    // Tornar a l'origen i tancar: amb follow-up ha de poder quedar Completat
    await page.getByRole('link', { name: /Obrir visita origen/i }).click()
    await expect(page).toHaveURL(new RegExp(`/field/orders/${sourceId}`), { timeout: 15_000 })

    await page.getByRole('button', { name: 'Tancar visita', exact: true }).click()
    await expect(page.getByText(/Tancar visita d'inspecció/i)).toBeVisible({ timeout: 10_000 })
    await expect(page.getByText(/Checklist incompleta/i)).toHaveCount(0)

    await page.getByRole('button', { name: /Marcar completada/i }).click()
    await expect(
      page.getByText(/Visita tancada; seguiment traspassat|Visita tancada/i),
    ).toBeVisible({ timeout: 25_000 })

    // Amb OS de reparació, l'origen ha de poder quedar Completat (no eternament En espera)
    await expect(page.getByRole('heading', { name: orderName })).toBeVisible()
    await expect(page.getByText('Completat', { exact: true }).first()).toBeVisible({
      timeout: 15_000,
    })
  })
})
