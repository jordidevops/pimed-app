import type { Page } from '@playwright/test'
import { expect } from '@playwright/test'
import { EHR_FIXTURES } from '../e2e-users'

const TENANT_IDS = {
  'Acme Corp': EHR_FIXTURES.acmeTenantId,
  'Beta Startup': EHR_FIXTURES.betaTenantId,
} as const

async function waitForDashboardShell(page: Page) {
  await expect(page.getByRole('heading', { name: 'Notes' })).toBeVisible({ timeout: 25_000 })
}

/** Assert sidebar shows the expected tenant (select or single-tenant badge). */
async function expectSidebarTenant(page: Page, tenantLabel: 'Acme Corp' | 'Beta Startup') {
  const tenantId = TENANT_IDS[tenantLabel]
  const tenantSelector = page.getByLabel('Selecciona organització')
  if ((await tenantSelector.count()) > 0) {
    await expect(tenantSelector).toHaveValue(tenantId, { timeout: 15_000 })
  } else {
    // When x-tenant-id scopes my_tenant to one row, the UI shows a badge instead of <select>.
    await expect(page.locator('aside').getByText(tenantLabel, { exact: true })).toBeVisible({
      timeout: 15_000,
    })
  }
}

/**
 * Pin tenant for e2e via sessionStorage before first paint (addInitScript).
 * TenantContext must not wipe storage while auth is still resolving.
 */
export async function pinTenant(page: Page, tenantLabel: 'Acme Corp' | 'Beta Startup') {
  const tenantId = TENANT_IDS[tenantLabel]

  await page.addInitScript((id: string) => {
    sessionStorage.setItem('selectedTenantId', id)
  }, tenantId)

  await page.goto('/dashboard')
  await waitForDashboardShell(page)
  await expectSidebarTenant(page, tenantLabel)
}

/** Select tenant and wait until context is stable. */
export async function selectTenant(page: Page, tenantLabel: 'Acme Corp' | 'Beta Startup') {
  await pinTenant(page, tenantLabel)
}

export async function gotoEmployeesAcme(page: Page) {
  await pinTenant(page, 'Acme Corp')
  await page.goto('/employees')
  await expect(page).toHaveURL(/\/employees\/?$/)
  await expectSidebarTenant(page, 'Acme Corp')
  await expect(page.getByTestId('employees-page-title')).toBeVisible({ timeout: 25_000 })
}

export async function gotoEmployeesBeta(page: Page) {
  await pinTenant(page, 'Beta Startup')
  await page.goto('/employees')
  await expect(page).toHaveURL(/\/employees\/?$/)
  await expectSidebarTenant(page, 'Beta Startup')
  await expect(page.getByTestId('employees-page-title')).toBeVisible({ timeout: 25_000 })
}

export { EHR_FIXTURES }
