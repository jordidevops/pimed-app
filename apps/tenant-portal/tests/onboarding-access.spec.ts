import { expect, test } from '@playwright/test'
import { AUTH_STATE_PATH } from './e2e-users'

test.describe('Onboarding access guard', () => {
  test.describe('Owner with pending onboarding', () => {
    test.use({ storageState: AUTH_STATE_PATH.bob })

    test('Bob can open /onboarding when sector_profile_id is NULL', async ({ page }) => {
      await page.goto('/onboarding')

      await expect(page).toHaveURL(/\/onboarding$/)
      await expect(page.getByRole('heading', { name: 'Quin és el teu sector?' })).toBeVisible()
    })
  })

  test.describe('Owner after completing onboarding', () => {
    test.use({ storageState: AUTH_STATE_PATH.bob })

    test('Bob is redirected away from /onboarding when sector_profile_id is already set', async ({ page }) => {
      // Simulem tenant ja onboarded perquè el guard depèn d'aquest camp.
      await page.route('**/rest/v1/my_tenant*', async (route) => {
        await route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify([
            {
              id: '10000000-0000-0000-0000-000000000001',
              name: 'Acme Corp',
              slug: 'acme-corp',
              plan_name: 'pro',
              plan_display_name: 'Pro',
              max_members: 20,
              max_sites: 5,
              sector_profile_id: '40000000-0000-0000-0000-000000000001',
              archetype: 'field_service',
              sector_icon: '🔧',
              sector_display_name: 'Serveis al Camp',
            },
          ]),
        })
      })

      await page.goto('/onboarding')
      // field_service home is /field/today (Dashboard redirects)
      await expect(page).toHaveURL(/\/(dashboard|field\/today)$/)
    })
  })

  test.describe('Non-owner with pending onboarding', () => {
    test.use({ storageState: AUTH_STATE_PATH.charlie })

    test('Charlie is redirected from /onboarding to /dashboard', async ({ page }) => {
      await page.goto('/onboarding')

      await expect(page).toHaveURL(/\/dashboard$/)
      await expect(page.getByRole('heading', { name: 'Notes' })).toBeVisible()
    })
  })
})
