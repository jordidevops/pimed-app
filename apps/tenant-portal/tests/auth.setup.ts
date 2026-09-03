import { expect, test as setup } from '@playwright/test'
import { mkdir } from 'node:fs/promises'
import { AUTH_STATE_PATH, E2E_USERS, EHR_FIXTURES } from './e2e-users'

setup('authenticate seed users and persist storage state', async ({ browser, baseURL }) => {
  setup.setTimeout(120_000)
  const users = [E2E_USERS.alice, E2E_USERS.bob, E2E_USERS.carol, E2E_USERS.charlie, E2E_USERS.dave]

  // Ensure auth directory exists in clean environments (first run, fresh CI).
  await mkdir('playwright/.auth', { recursive: true })

  for (const user of users) {
    // Start with an explicit empty state to avoid trying to read missing files
    // from the default `use.storageState` config.
    const context = await browser.newContext({
      baseURL,
      storageState: { cookies: [], origins: [] },
    })
    const page = await context.newPage()

    await page.goto('/login')
    await expect(page.locator('#email')).toBeVisible({ timeout: 20_000 })

    await page.locator('#email').fill(user.email)
    await page.locator('#password').fill(user.password)
    await page.locator('form button[type="submit"]').first().click()

    await expect(page).not.toHaveURL(/\/login$/)
    const dashboardHeading = page.getByRole('heading', { name: 'Notes' })
    const onboardingHeading = page.getByRole('heading', { name: 'Quin és el teu sector?' })
    // field_service tenants (e.g. Volt) land on /field/today instead of Notes
    const fieldTodayHeading = page.getByRole('heading', { name: /^Avui$/i })

    await Promise.race([
      dashboardHeading.waitFor({ state: 'visible', timeout: 10_000 }),
      onboardingHeading.waitFor({ state: 'visible', timeout: 10_000 }),
      fieldTodayHeading.waitFor({ state: 'visible', timeout: 10_000 }),
    ])

    const tenantSelector = page.getByLabel('Selecciona organització')
    if (await tenantSelector.count()) {
      let selectedTenantId = await tenantSelector.inputValue()
      // Prefer Acme for Alice/Charlie/Dave so employee e2e is not trapped on Beta onboarding.
      const acmeOption = tenantSelector.getByRole('option', { name: 'Acme Corp' })
      if (await acmeOption.count()) {
        await tenantSelector.selectOption({ label: 'Acme Corp' })
        selectedTenantId = EHR_FIXTURES.acmeTenantId
        // Acme may land on Notes or onboarding (no sector yet).
        await Promise.race([
          page.getByRole('heading', { name: 'Notes' }).waitFor({ state: 'visible', timeout: 20_000 }),
          page
            .getByRole('heading', { name: 'Quin és el teu sector?' })
            .waitFor({ state: 'visible', timeout: 20_000 }),
        ])
      } else if (!selectedTenantId) {
        const options = tenantSelector.locator('option')
        const optionCount = await options.count()
        for (let idx = 0; idx < optionCount; idx += 1) {
          const value = await options.nth(idx).getAttribute('value')
          if (value) {
            await tenantSelector.selectOption(value)
            selectedTenantId = value
            break
          }
        }
      }

      if (selectedTenantId) {
        await page.evaluate((tenantId) => {
          document.cookie = `e2e_selected_tenant_id=${encodeURIComponent(tenantId)}; path=/; SameSite=Lax`
        }, selectedTenantId)
      }
    }

    await context.storageState({ path: AUTH_STATE_PATH[user.key] })
    await context.close()
  }
})
