import { expect, test } from '@playwright/test'
import { AUTH_STATE_PATH } from './e2e-users'

test.describe('Site quota - Free plan', () => {
  test.use({ storageState: AUTH_STATE_PATH.carol })

  test('Carol cannot create a second site in Beta Startup (max 1 site)', async ({ page }) => {
    await page.goto('/settings')

    const tenantSelector = page.getByLabel('Selecciona organització')
    await tenantSelector.waitFor({ state: 'visible' })

    if (await tenantSelector.getByRole('option', { name: 'Beta Startup' }).count()) {
      await tenantSelector.selectOption({ label: 'Beta Startup' })
      await page.waitForURL(/\/dashboard$/)
      await page.goto('/settings')

      await expect(page.getByLabel('Selecciona organització')).toHaveValue(
        '10000000-0000-0000-0000-000000000002',
      )
    }

    await expect(page.getByRole('heading', { name: 'Gestió de Locals' })).toBeVisible()

    const createSiteButton = page.getByRole('button', { name: 'Nou Local' })
    await expect(createSiteButton).toBeDisabled()

    await expect(
      page.getByText('Has assolit el límit de locals del teu pla. Millora el pla per afegir-ne més.'),
    ).toBeVisible()
  })
})
