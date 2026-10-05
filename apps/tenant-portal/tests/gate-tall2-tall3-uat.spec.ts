/**
 * Gate Tall 2→3 — UAT online de qualitat de dades (hores/materials/km/despeses + cost/PVP).
 * Spec: docs/plans/commercial-flow/08-gate-tall2-tall3.md checklist O1–O7.
 * No substitueix UAT humana multi-dia ni offline en mòbil real (F1–F6).
 */
import { expect, test, type Page } from '@playwright/test'
import { AUTH_STATE_PATH, EHR_FIXTURES } from './e2e-users'

const VOLT_TENANT_ID = EHR_FIXTURES.voltTenantId

async function pinVoltTenant(page: Page) {
  await page.addInitScript((id: string) => {
    sessionStorage.setItem('selectedTenantId', id)
  }, VOLT_TENANT_ID)

  await page.goto('/field/today')
  await expect(page).toHaveURL(/\/field\/today/, { timeout: 25_000 })
  await expect(page.getByLabel('Selecciona organització')).toHaveValue(VOLT_TENANT_ID, {
    timeout: 15_000,
  })
}

async function createVoltOrder(page: Page, name: string): Promise<string> {
  await page.goto('/field/orders')
  await expect(
    page.getByRole('heading', { name: /Ordres de servei|Ordre de servei/i }),
  ).toBeVisible({ timeout: 15_000 })

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
  if (!match?.[1]) throw new Error("No s'ha pogut llegir l'id de l'ordre creada")
  return match[1]
}

async function openDoTab(page: Page, orderId: string) {
  await page.goto(`/field/orders/${orderId}?tab=do`)
  await expect(page).toHaveURL(new RegExp(`${orderId}\\?tab=do`))
  await expect(page.getByRole('tab', { name: /Fer/i })).toHaveAttribute('data-state', 'active', {
    timeout: 15_000,
  })
}

async function ensureWorkStarted(page: Page, context: import('@playwright/test').BrowserContext) {
  await context.grantPermissions(['geolocation'])
  await context.setGeolocation({ latitude: 41.392, longitude: 2.152 })

  const running = page.getByRole('button', { name: /Aturar|Temps en curs/i }).first()
  if (await running.isVisible().catch(() => false)) return

  const start = page
    .getByRole('button', { name: /Iniciar feina|Iniciar visita|Reprendre feina/i })
    .first()
  await expect(start).toBeVisible({ timeout: 15_000 })
  await start.click()
  await expect(page.getByRole('button', { name: /Aturar|Temps en curs/i }).first()).toBeVisible({
    timeout: 20_000,
  })
}

async function addMaterialAndAmounts(page: Page, materialName: string) {
  await page.getByRole('button', { name: /Mostrar Materials|Materials/i }).first().click()
  const materialsRegion = page.locator('#work-materials')
  await expect(materialsRegion).toBeVisible({ timeout: 10_000 })

  await materialsRegion.getByPlaceholder(/^Material$/i).fill(materialName)
  await materialsRegion.getByPlaceholder(/Quantitat/i).fill('2')
  await materialsRegion.getByPlaceholder(/Unitat/i).fill('u')
  await materialsRegion.getByRole('button', { name: /^Afegir$/i }).click()
  await expect(materialsRegion.getByText(materialName)).toBeVisible({ timeout: 15_000 })

  const row = materialsRegion.locator('li').filter({ hasText: materialName }).first()
  const pvp = row.locator('label').filter({ hasText: /PVP/i }).locator('input')
  const cost = row.locator('label').filter({ hasText: /Cost/i }).locator('input')
  await expect(pvp).toBeVisible()
  await expect(cost).toBeVisible()
  await pvp.fill('25.50')
  await pvp.blur()
  await cost.fill('12.00')
  await cost.blur()
  await expect(pvp).toHaveValue(/25[,.]50/)
  await expect(cost).toHaveValue(/12[,.]00/)
}

async function addBillableEmployeeExpense(page: Page, description: string) {
  await page.getByRole('button', { name: /Mostrar Despeses|Despeses/i }).first().click()
  const expensesRegion = page.locator('#work-expenses')
  await expect(expensesRegion).toBeVisible({ timeout: 10_000 })

  await expensesRegion.getByPlaceholder(/Descripció/i).fill(description)
  await expensesRegion.getByPlaceholder(/Import/i).fill('8.75')
  await expensesRegion.getByLabel(/Imputable al client/i).check()
  await expensesRegion.locator('select').selectOption('employee')
  await expensesRegion.getByRole('button', { name: /^Afegir$/i }).click()

  await expect(expensesRegion.getByText(description)).toBeVisible({ timeout: 15_000 })
  await expect(expensesRegion.getByText(/Imputable/i).first()).toBeVisible()
  await expect(expensesRegion.getByText(/Paga empleat/i).first()).toBeVisible()
}

test.describe('Gate Tall 2→3 UAT online (Volt)', () => {
  test.describe.configure({ timeout: 180_000 })
  test.use({ storageState: AUTH_STATE_PATH.alice })

  test('O1–O7: fitxatge, materials+cost/PVP, despeses flags, reload sense pèrdua (2 OS)', async ({
    page,
    context,
  }) => {
    await pinVoltTenant(page)

    const stamp = Date.now()
    const orderIds: string[] = []

    for (const idx of [1, 2] as const) {
      const orderName = `Gate T2-T3 UAT ${stamp}-${idx}`
      const materialName = `Cable UAT ${stamp}-${idx}`
      const expenseName = `Parking UAT ${stamp}-${idx}`

      const orderId = await createVoltOrder(page, orderName)
      orderIds.push(orderId)

      await openDoTab(page, orderId)
      await ensureWorkStarted(page, context)

      await addMaterialAndAmounts(page, materialName)
      await addBillableEmployeeExpense(page, expenseName)

      // O7: reload + altra pestanya = mateixa pàgina reload
      await page.reload({ waitUntil: 'domcontentloaded' })
      await openDoTab(page, orderId)

      await page.getByRole('button', { name: /Mostrar Materials|Materials/i }).first().click()
      const materialsRegion = page.locator('#work-materials')
      await expect(materialsRegion.getByText(materialName)).toBeVisible({ timeout: 15_000 })
      const row = materialsRegion.locator('li').filter({ hasText: materialName }).first()
      await expect(row.locator('label').filter({ hasText: /PVP/i }).locator('input')).toHaveValue(
        /25[,.]50/,
      )
      await expect(row.locator('label').filter({ hasText: /Cost/i }).locator('input')).toHaveValue(
        /12[,.]00/,
      )

      await page.getByRole('button', { name: /Mostrar Despeses|Despeses/i }).first().click()
      const expensesRegion = page.locator('#work-expenses')
      await expect(expensesRegion.getByText(expenseName)).toBeVisible({ timeout: 15_000 })
      await expect(expensesRegion.getByText(/Imputable/i).first()).toBeVisible()
      await expect(expensesRegion.getByText(/Paga empleat/i).first()).toBeVisible()

      // O4: aturar interval si encara corre
      const stop = page.getByRole('button', { name: /^Aturar$/i }).first()
      if (await stop.isVisible().catch(() => false)) {
        await stop.click()
        await expect(page.getByRole('button', { name: /Iniciar|Reprendre/i }).first()).toBeVisible({
          timeout: 20_000,
        })
      }
    }

    expect(orderIds).toHaveLength(2)
  })
})
