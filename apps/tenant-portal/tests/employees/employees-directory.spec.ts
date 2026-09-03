import { expect, test } from '@playwright/test'
import { AUTH_STATE_PATH, EHR_FIXTURES } from '../e2e-users'
import { gotoEmployeesAcme, selectTenant } from './employees-helpers'

test.describe('Employees directory / lifecycle / contracts', () => {
  test.describe.configure({ timeout: 60_000 })
  test.use({ storageState: AUTH_STATE_PATH.alice })

  test('E4 Create employee via UI and open detail', async ({ page }) => {
    const suffix = Date.now().toString().slice(-6)
    const fullName = `QA E2E Emp ${suffix}`

    await gotoEmployeesAcme(page)
    await expect(page.getByTestId('employees-new')).toBeVisible({ timeout: 20_000 })
    await page.getByTestId('employees-new').click()

    const dialog = page.getByRole('dialog')
    await expect(dialog).toBeVisible()
    await dialog
      .getByPlaceholder(/Anna Garcia|nom|name/i)
      .first()
      .fill(fullName)
    const saveBtn = dialog.getByRole('button', { name: /Desar|Guardar|Crear|Save/i })
    await saveBtn.scrollIntoViewIfNeeded()
    await saveBtn.click({ force: true })

    await page.getByTestId('employees-search').fill(fullName)
    await expect(page.getByText(fullName).first()).toBeVisible({ timeout: 20_000 })
    await page.getByText(fullName).first().click()
    await expect(page.getByTestId('employee-detail-name')).toHaveText(fullName, { timeout: 15_000 })
  })

  test('E7 QA Smoke shows onboarding lifecycle and readiness badge', async ({ page }) => {
    await selectTenant(page, 'Acme Corp')
    await page.goto(`/employees/${EHR_FIXTURES.qaSmokeEmployeeId}`)
    await expect(page.getByTestId('employee-detail-name')).toHaveText(EHR_FIXTURES.qaSmokeName, {
      timeout: 20_000,
    })
    await expect(page.getByTestId('employee-readiness-badge')).toBeVisible({ timeout: 15_000 })
    await expect(page.getByTestId('employee-lifecycle-state')).toContainText(/onboarding/i)
  })

  test('E10 Draft contract visible on QA Smoke contracts tab', async ({ page }) => {
    await selectTenant(page, 'Acme Corp')
    await page.goto(`/employees/${EHR_FIXTURES.qaSmokeEmployeeId}?tab=contracts`)
    await expect(page.getByTestId('employee-contracts')).toBeVisible({ timeout: 20_000 })
    await expect(page.getByText('QA-SMOKE-DRAFT-001')).toBeVisible()
    await expect(page.getByText(/draft|esborrany|pending|pendent|signatura/i).first()).toBeVisible()
  })

  test('E9 Offboard employee equipment / checklist surface', async ({ page }) => {
    await selectTenant(page, 'Acme Corp')
    await page.goto(`/employees/${EHR_FIXTURES.qaOffboardEmployeeId}`)
    await expect(page.getByTestId('employee-detail-name')).toHaveText('QA Offboard Employee', {
      timeout: 20_000,
    })
    await expect(page.getByText(/offboarding/i).first()).toBeVisible()
  })
})
