import { expect, test } from '@playwright/test'
import { AUTH_STATE_PATH } from './e2e-users'

test.describe('Site isolation - Bob', () => {
  test.use({ storageState: AUTH_STATE_PATH.bob })

  test('Bob only sees Acme Gracia notes when that site is selected', async ({ page }) => {
    await page.goto('/dashboard')

    await expect(page.getByRole('heading', { name: 'Acme Corp' })).toBeVisible()

    await page.getByLabel('Selecciona local').selectOption({ label: 'Acme Gràcia' })

    await expect(page.getByText('Acme Gràcia Daily Ops')).toBeVisible()
    await expect(page.getByText('Acme Sants Maintenance')).toHaveCount(0)
    await expect(page.getByText('Beta Workshop Checklist')).toHaveCount(0)
  })
})

test.describe('Site isolation - Alice', () => {
  test.use({ storageState: AUTH_STATE_PATH.alice })

  test('Alice in Acme global view sees all Acme notes and the tenant global note', async ({ page }) => {
    await page.goto('/dashboard')

    await page.getByLabel('Selecciona organització').selectOption({ label: 'Acme Corp' })

    const siteSelector = page.getByLabel('Selecciona local')
    const globalOption = siteSelector.getByRole('option', { name: 'Vista Global' })
    if (await globalOption.count()) {
      await siteSelector.selectOption({ label: 'Vista Global' })
    }

    await expect(page.getByText('Acme Global Policy')).toBeVisible()
    await expect(page.getByText('Acme Gràcia Daily Ops')).toBeVisible()
    await expect(page.getByText('Acme Sants Maintenance')).toBeVisible()
    await expect(page.getByText('Beta Workshop Checklist')).toHaveCount(0)
  })
})
