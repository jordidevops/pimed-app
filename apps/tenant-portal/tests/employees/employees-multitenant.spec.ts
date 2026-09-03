import { expect, test } from '@playwright/test'
import { AUTH_STATE_PATH, EHR_FIXTURES } from '../e2e-users'
import { gotoEmployeesAcme, gotoEmployeesBeta, selectTenant } from './employees-helpers'

test.describe('Employees multi-tenant', () => {
  test.describe.configure({ timeout: 60_000 })
  test.describe('Acme (Alice)', () => {
    test.use({ storageState: AUTH_STATE_PATH.alice })

    test('E24 Acme list contains QA Smoke and not Beta fixture name', async ({ page }) => {
      await gotoEmployeesAcme(page)
      await page.getByTestId('employees-search').fill('QA Smoke')
      await expect(page.getByRole('link', { name: new RegExp(EHR_FIXTURES.qaSmokeName) })).toBeVisible({
        timeout: 15_000,
      })
      await expect(page.getByText(EHR_FIXTURES.qaBetaName)).toHaveCount(0)
    })
  })

  test.describe('Beta (Alice switches tenant)', () => {
    test.use({ storageState: AUTH_STATE_PATH.alice })

    test('E25 Beta search does not find Acme QA Smoke email', async ({ page }) => {
      await gotoEmployeesBeta(page)
      await page.getByTestId('employees-search').fill(EHR_FIXTURES.qaSmokeEmail)
      await expect(page.getByText(EHR_FIXTURES.qaSmokeName)).toHaveCount(0)
      await expect(page.getByText(EHR_FIXTURES.qaSmokeEmail)).toHaveCount(0)
      await expect(
        page.getByText(/Cap empleat coincideix|Encara no hi ha empleats/i),
      ).toBeVisible({ timeout: 15_000 })
    })

    test('E26 Beta cannot open Acme QA Smoke employee by direct URL', async ({ page }) => {
      await selectTenant(page, 'Beta Startup')
      await page.goto(`/employees/${EHR_FIXTURES.qaSmokeEmployeeId}`)
      await expect(page.getByTestId('employee-not-found')).toBeVisible({ timeout: 20_000 })
      await expect(page.getByText(EHR_FIXTURES.qaSmokeName)).toHaveCount(0)
      await expect(page.getByText(EHR_FIXTURES.qaSmokeEmail)).toHaveCount(0)
    })

    test('E27 Beta sees QA Beta employee contracts without Acme draft', async ({ page }) => {
      await gotoEmployeesBeta(page)
      await page.getByTestId('employees-search').fill('QA Beta')
      await expect(page.getByText(EHR_FIXTURES.qaBetaName).first()).toBeVisible({
        timeout: 15_000,
      })
      await page.goto(`/employees/${EHR_FIXTURES.qaBetaEmployeeId}?tab=contracts`)
      await expect(page.getByTestId('employee-contracts')).toBeVisible({ timeout: 20_000 })
      await expect(page.getByText('QA-SMOKE-DRAFT-001')).toHaveCount(0)
      await expect(page.getByText(/QA-BETA-ACTIVE-001/)).toBeVisible({ timeout: 15_000 })
    })
  })
})
