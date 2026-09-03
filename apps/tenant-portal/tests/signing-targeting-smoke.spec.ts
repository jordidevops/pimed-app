import { expect, test } from '@playwright/test'
import { AUTH_STATE_PATH } from './e2e-users'

type TemplateRow = {
  id: string
  tenant_id: string | null
  name: string
  description: string | null
  category: string | null
  is_platform_default: boolean
  cloned_from_id: string | null
  is_active: boolean
  created_by: string | null
  created_at: string
  updated_at: string
  template_type: 'docx' | 'html'
  target_archetypes: string[] | null
  target_verticals: string[] | null
}

const TENANT_ID = '10000000-0000-0000-0000-000000000001'

function nowIso() {
  return new Date().toISOString()
}

function mockTenantContextRoutes(page: Parameters<typeof test>[0]['page']) {
  page.route('**/rest/v1/my_tenant*', async (route) => {
    if (route.request().method() !== 'GET') {
      await route.continue()
      return
    }
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify([
        {
          id: TENANT_ID,
          name: 'Acme Corp',
          slug: 'acme-corp',
          plan_name: 'pro',
          plan_display_name: 'Pro',
          max_members: 100,
          max_sites: 10,
          sector_profile_id: '20000000-0000-0000-0000-000000000001',
          archetype: 'hospitality',
          sector_icon: 'briefcase',
          sector_display_name: 'Hospitality',
          sector_vertical: 'restaurant',
        },
      ]),
    })
  })

  page.route('**/rest/v1/tenant_members*', async (route) => {
    if (route.request().method() !== 'GET') {
      await route.continue()
      return
    }
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify([
        {
          tenant_id: TENANT_ID,
          role: 'owner',
          site_id: null,
        },
      ]),
    })
  })
}

function mockTemplatesListRoutes(page: Parameters<typeof test>[0]['page'], templates: TemplateRow[]) {
  page.route('**/rest/v1/document_templates*', async (route) => {
    if (route.request().method() !== 'GET') {
      await route.continue()
      return
    }
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(templates),
    })
  })

  page.route('**/rest/v1/document_template_locales*', async (route) => {
    if (route.request().method() !== 'GET') {
      await route.continue()
      return
    }
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify([]),
    })
  })
}

test.describe('Signing templates targeting smoke', () => {
  test.use({ storageState: AUTH_STATE_PATH.alice })

  test.beforeEach(async ({ page }) => {
    await page.addInitScript((tenantId) => {
      sessionStorage.setItem('selectedTenantId', tenantId)
    }, TENANT_ID)
  })

  test('create template sends targeting arrays to RPC', async ({ page }) => {
    mockTenantContextRoutes(page)
    mockTemplatesListRoutes(page, [])

    let createPayload: Record<string, unknown> | null = null

    await page.route('**/rest/v1/rpc/create_document_template', async (route) => {
      if (route.request().method() !== 'POST') {
        await route.continue()
        return
      }

      createPayload = route.request().postDataJSON() as Record<string, unknown>
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({
          id: '9f000000-0000-0000-0000-000000000001',
          tenant_id: TENANT_ID,
          name: 'Targeted Template',
          description: null,
          category: 'hr',
          template_type: 'docx',
          is_platform_default: false,
          cloned_from_id: null,
          is_active: true,
          created_by: '00000000-0000-0000-0000-000000000000',
          created_at: nowIso(),
          updated_at: nowIso(),
          target_archetypes: ['hospitality', 'generic'],
          target_verticals: ['restaurant', 'catering'],
        }),
      })
    })

    await page.goto('/documents/templates')
    await expect(page.getByRole('heading', { name: 'Plantilles de documents' })).toBeVisible()

    await page.getByRole('button', { name: 'Nova plantilla' }).click()
    await page.getByPlaceholder('Nom...').fill('Targeted Template')
    await page.getByRole('button', { name: 'hospitality' }).click()
    await page.getByRole('button', { name: 'generic' }).click()
    await page.getByPlaceholder('restaurant, clinic, garage...').fill('Restaurant, Catering, restaurant')
    await page.getByRole('button', { name: 'Crear plantilla' }).click()

    await expect.poll(() => createPayload).not.toBeNull()
    expect(createPayload?.p_target_archetypes).toEqual(['hospitality', 'generic'])
    expect(createPayload?.p_target_verticals).toEqual(['restaurant', 'catering'])
  })

  test('sector filter keeps only matching templates', async ({ page }) => {
    mockTenantContextRoutes(page)

    const templates: TemplateRow[] = [
      {
        id: '9f000000-0000-0000-0000-000000000011',
        tenant_id: TENANT_ID,
        name: 'Template Match Hospitality',
        description: null,
        category: 'hr',
        is_platform_default: false,
        cloned_from_id: null,
        is_active: true,
        created_by: '00000000-0000-0000-0000-000000000000',
        created_at: nowIso(),
        updated_at: nowIso(),
        template_type: 'docx',
        target_archetypes: ['hospitality'],
        target_verticals: null,
      },
      {
        id: '9f000000-0000-0000-0000-000000000012',
        tenant_id: TENANT_ID,
        name: 'Template No Match Practice',
        description: null,
        category: 'hr',
        is_platform_default: false,
        cloned_from_id: null,
        is_active: true,
        created_by: '00000000-0000-0000-0000-000000000000',
        created_at: nowIso(),
        updated_at: nowIso(),
        template_type: 'docx',
        target_archetypes: ['practice'],
        target_verticals: null,
      },
    ]

    mockTemplatesListRoutes(page, templates)

    await page.goto('/documents/templates')

    await expect(page.getByText('Template Match Hospitality')).toBeVisible()
    await expect(page.getByText('Template No Match Practice')).toBeVisible()

    await page.getByRole('button', { name: 'Per al meu sector' }).click()

    await expect(page.getByText('Template Match Hospitality')).toBeVisible()
    await expect(page.getByText('Template No Match Practice')).toHaveCount(0)
  })

  test('clone template preserves target archetypes and verticals', async ({ page }) => {
    mockTenantContextRoutes(page)

    const templates: TemplateRow[] = [
      {
        id: '9f000000-0000-0000-0000-000000000021',
        tenant_id: null,
        name: 'Platform Targeted Template',
        description: 'platform',
        category: 'operations',
        is_platform_default: true,
        cloned_from_id: null,
        is_active: true,
        created_by: '00000000-0000-0000-0000-000000000000',
        created_at: nowIso(),
        updated_at: nowIso(),
        template_type: 'docx',
        target_archetypes: ['hospitality', 'workshop_maker'],
        target_verticals: ['restaurant'],
      },
    ]

    mockTemplatesListRoutes(page, templates)

    page.route('**/rest/v1/document_template_locale_detail*', async (route) => {
      if (route.request().method() !== 'GET') {
        await route.continue()
        return
      }
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify([]),
      })
    })

    let clonePayload: Record<string, unknown> | null = null
    await page.route('**/rest/v1/rpc/create_document_template', async (route) => {
      if (route.request().method() !== 'POST') {
        await route.continue()
        return
      }
      clonePayload = route.request().postDataJSON() as Record<string, unknown>
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({
          id: '9f000000-0000-0000-0000-000000000099',
          tenant_id: TENANT_ID,
          name: 'Platform Targeted Template',
          description: 'platform',
          category: 'operations',
          template_type: 'docx',
          is_platform_default: false,
          cloned_from_id: '9f000000-0000-0000-0000-000000000021',
          is_active: true,
          created_by: '00000000-0000-0000-0000-000000000000',
          created_at: nowIso(),
          updated_at: nowIso(),
          target_archetypes: ['hospitality', 'workshop_maker'],
          target_verticals: ['restaurant'],
        }),
      })
    })

    await page.goto('/documents/templates')
    await page.getByRole('tab', { name: 'Plantilles del sistema' }).click()
    await page.getByRole('button', { name: 'Clonar per personalitzar', exact: true }).click()

    await expect.poll(() => clonePayload).not.toBeNull()
    expect(clonePayload?.p_cloned_from_id).toBe('9f000000-0000-0000-0000-000000000021')
    expect(clonePayload?.p_target_archetypes).toEqual(['hospitality', 'workshop_maker'])
    expect(clonePayload?.p_target_verticals).toEqual(['restaurant'])
  })
})
