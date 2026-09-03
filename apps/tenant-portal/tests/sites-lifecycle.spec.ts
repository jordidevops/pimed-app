import { expect, test } from '@playwright/test'
import { AUTH_STATE_PATH } from './e2e-users'

test.describe('Sites lifecycle - Alice', () => {
  test.use({ storageState: AUTH_STATE_PATH.alice })

  test('Alice can create, deactivate, and reactivate a site from settings', async ({ page }) => {
    const uniqueSuffix = Date.now()
    const siteName = `PW Site ${uniqueSuffix}`
    const siteAddress = `Carrer Playwright ${uniqueSuffix}`

    await page.goto('/settings')

    const tenantSelector = page.getByLabel('Selecciona organització')
    if (await tenantSelector.count()) {
      await tenantSelector.selectOption({ label: 'Acme Corp' })
      await page.goto('/settings')
    }

    const settingsSection = page.locator('#locals')
    await expect(settingsSection).toBeVisible()

    await page.getByRole('button', { name: 'Nou Local' }).click()
    await page.getByLabel('Nom del local').fill(siteName)
    await page.getByLabel('Adreça').fill(siteAddress)
    await page.getByRole('button', { name: 'Crear local' }).click()

    const activeList = settingsSection.locator('ul').first()
    await expect(activeList.getByText(siteName)).toBeVisible()

    const activeRow = activeList.locator('li').filter({ hasText: siteName })
    await activeRow.getByRole('button', { name: 'Desactivar' }).click()
    await expect(activeList.getByText(siteName)).toHaveCount(0)

    await page.getByRole('button', { name: 'Mostrar arxiu de locals inactius' }).click()

    const archiveList = settingsSection.locator('ul').nth(1)
    const archiveRow = archiveList.locator('li').filter({ hasText: siteName })
    await expect(archiveRow).toBeVisible()

    await archiveRow.getByRole('button', { name: 'Reactivar' }).click()
    await expect(activeList.getByText(siteName)).toBeVisible()
  })
})
