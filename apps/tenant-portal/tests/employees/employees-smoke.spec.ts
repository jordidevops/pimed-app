import { expect, test } from '@playwright/test'
import { AUTH_STATE_PATH, EHR_FIXTURES } from '../e2e-users'
import { gotoEmployeesAcme, selectTenant } from './employees-helpers'

test.describe('Employees smoke', () => {
  test.describe.configure({ timeout: 60_000 })
  test.use({ storageState: AUTH_STATE_PATH.alice })

  test('E1 Alice employees list loads with rows', async ({ page }) => {
    await gotoEmployeesAcme(page)
    await expect(page.getByTestId('employees-search')).toBeVisible()
    await page.getByTestId('employees-search').fill('Alice')
    await expect(page.getByText(/Alice/i).first()).toBeVisible({ timeout: 15_000 })
  })

  test('E2 Detail tabs contracts / certifications / equipment load', async ({ page }) => {
    await selectTenant(page, 'Acme Corp')
    await page.goto(`/employees/${EHR_FIXTURES.qaSmokeEmployeeId}`)
    await expect(page.getByTestId('employee-detail-name')).toHaveText(EHR_FIXTURES.qaSmokeName, {
      timeout: 20_000,
    })
    await expect(page.getByTestId('employee-readiness-badge')).toBeVisible({ timeout: 15_000 })

    await page.goto(`/employees/${EHR_FIXTURES.qaSmokeEmployeeId}?tab=contracts`)
    await expect(page.getByTestId('employee-contracts')).toBeVisible({ timeout: 20_000 })
    await expect(page.getByText('QA-SMOKE-DRAFT-001')).toBeVisible()

    await page.goto(`/employees/${EHR_FIXTURES.aliceEmployeeId}?tab=certifications`)
    await expect(page.getByTestId('employee-certifications')).toBeVisible({ timeout: 20_000 })

    await page.goto(`/employees/${EHR_FIXTURES.qaSmokeEmployeeId}?tab=equipment`)
    await expect(page.getByText('Equipament assignat')).toBeVisible({ timeout: 20_000 })
    await expect(page.getByText(/QA EPI Casc Smoke/i)).toBeVisible()
  })

  test('E3 HR / organization / positions / skills routes render', async ({ page }) => {
    await selectTenant(page, 'Acme Corp')
    await page.goto('/employees/hr')
    await expect(page.getByRole('heading', { name: 'Reporting HR' })).toBeVisible({
      timeout: 20_000,
    })

    await page.goto('/employees/organization')
    await expect(page.getByText(/Organigrama|sense manager|arrels/i).first()).toBeVisible({
      timeout: 20_000,
    })

    await page.goto('/employees/positions')
    await expect(page.getByRole('heading', { name: /Posicions/i })).toBeVisible({ timeout: 20_000 })

    await page.goto('/employees/skills')
    await expect(page.getByText('Skills (talent)')).toBeVisible({ timeout: 20_000 })
  })
})
