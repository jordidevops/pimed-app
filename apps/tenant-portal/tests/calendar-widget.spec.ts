import { expect, test } from '@playwright/test'
import { AUTH_STATE_PATH } from './e2e-users'

test.describe('Calendar widget', () => {
  test.use({ storageState: AUTH_STATE_PATH.alice })

  test('desktop renders calendar shell and month grid', async ({ page }) => {
    await page.goto('/dashboard')

    const tenantSelector = page.getByLabel('Selecciona organització')
    if (await tenantSelector.count()) {
      await tenantSelector.selectOption({ label: 'Acme Corp' })
    }

    const calendar = page.getByTestId('calendar-widget')
    await expect(calendar).toBeVisible()
    await expect(page.getByTestId('calendar-desktop-view')).toBeVisible()
    await expect(page.getByTestId('calendar-nav-prev')).toBeVisible()
    await expect(page.getByTestId('calendar-nav-next')).toBeVisible()
  })

  test('mobile renders week strip and agenda panel', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 })
    await page.goto('/dashboard')

    const tenantSelector = page.getByLabel('Selecciona organització')
    if (await tenantSelector.count()) {
      await tenantSelector.selectOption({ label: 'Acme Corp' })
    }

    await expect(page.getByTestId('calendar-mobile-view')).toBeVisible()
    await expect(page.getByTestId('calendar-mobile-week-strip')).toBeVisible()
    await expect(page.getByTestId('calendar-mobile-agenda')).toBeVisible()
  })
})
