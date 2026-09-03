import { expect, test } from '@playwright/test'
import { AUTH_STATE_PATH, EHR_FIXTURES } from '../e2e-users'
import { gotoEmployeesAcme, selectTenant } from './employees-helpers'

test.describe('Employees RBAC', () => {
  test.describe.configure({ timeout: 60_000 })
  test.describe('Alice owner', () => {
    test.use({ storageState: AUTH_STATE_PATH.alice })

    test('E21a Alice sees tech and medical certifications on seed employee', async ({ page }) => {
      await selectTenant(page, 'Acme Corp')
      await page.goto(`/employees/${EHR_FIXTURES.aliceEmployeeId}?tab=certifications`)
      const panel = page.getByTestId('employee-certifications')
      await expect(panel).toBeVisible({ timeout: 20_000 })
      await expect(panel.getByText(EHR_FIXTURES.heightCertName).first()).toBeVisible()
      await expect(panel.getByText(EHR_FIXTURES.medicalCertName).first()).toBeVisible()
    })
  })

  test.describe('Charlie site manager', () => {
    test.use({ storageState: AUTH_STATE_PATH.charlie })

    test('E21 Charlie sees tech certs but not medical', async ({ page }) => {
      await selectTenant(page, 'Acme Corp')
      await page.goto(`/employees/${EHR_FIXTURES.aliceEmployeeId}?tab=certifications`)
      const panel = page.getByTestId('employee-certifications')
      await expect(panel).toBeVisible({ timeout: 20_000 })
      await expect(panel.getByText(EHR_FIXTURES.heightCertName).first()).toBeVisible()
      await expect(panel.getByText(EHR_FIXTURES.medicalCertName)).toHaveCount(0)
    })
  })

  test.describe('Dave member', () => {
    test.use({ storageState: AUTH_STATE_PATH.dave })

    test('E22 Dave has no compliance management tab on employees hub', async ({ page }) => {
      await gotoEmployeesAcme(page)
      await expect(page.getByRole('button', { name: 'Compliment' })).toHaveCount(0)
    })
  })
})
