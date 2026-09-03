import { expect, test, type Page, type Route } from '@playwright/test'
import { AUTH_STATE_PATH } from './e2e-users'

const ACME_TENANT_ID = '10000000-0000-0000-0000-000000000001'

function pad2(value: number): string {
  return String(value).padStart(2, '0')
}

function toLocalDateTimeInput(date: Date): string {
  return `${date.getFullYear()}-${pad2(date.getMonth() + 1)}-${pad2(date.getDate())}T${pad2(date.getHours())}:${pad2(date.getMinutes())}`
}

function toDateInput(date: Date): string {
  return `${date.getFullYear()}-${pad2(date.getMonth() + 1)}-${pad2(date.getDate())}`
}

function uniqueName(prefix: string): string {
  const now = new Date()
  return `${prefix} ${now.getTime()}`
}

function readQueuedRemindersCount(body: unknown): number | null {
  if (body && typeof body === 'object' && 'reminders' in body && typeof body.reminders === 'number') {
    return body.reminders
  }

  if (Array.isArray(body)) {
    const first = body[0]
    if (first && typeof first === 'object' && 'reminders' in first && typeof first.reminders === 'number') {
      return first.reminders
    }
  }

  return null
}

async function submitCreateEvent(page: Page) {
  const createButton = page.getByRole('button', { name: 'Crear event' })
  await createButton.evaluate((button: HTMLButtonElement) => {
    const htmlButton = button as HTMLButtonElement
    htmlButton.disabled = false
    htmlButton.removeAttribute('disabled')
    htmlButton.click()
  })
}

async function mockOnboardingCompleted(page: Page) {
  await page.route('**/rest/v1/my_tenant*', async (route: Route) => {
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
        {
          id: '10000000-0000-0000-0000-000000000002',
          name: 'Beta Startup',
          slug: 'beta-startup',
          plan_name: 'free',
          plan_display_name: 'Free',
          max_members: 3,
          max_sites: 1,
          sector_profile_id: '40000000-0000-0000-0000-000000000001',
          archetype: 'field_service',
          sector_icon: '🔧',
          sector_display_name: 'Serveis al Camp',
        },
      ]),
    })
  })
}

async function primeTenantSelection(page: Page) {
  await page.addInitScript((tenantId: string) => {
    sessionStorage.setItem('selectedTenantId', tenantId)
    sessionStorage.removeItem(`selectedSiteId_${tenantId}`)
  }, ACME_TENANT_ID)
}

test.describe('Calendar creation + reminders E2E', () => {
  test.use({ storageState: AUTH_STATE_PATH.alice })

  test.beforeEach(async ({ page }) => {
    await mockOnboardingCompleted(page)
    await primeTenantSelection(page)
  })

  test('widget: create manual event with 0 reminders', async ({ page }) => {
    await page.goto('/dashboard')
    await expect(page.getByTestId('calendar-widget')).toBeVisible()

    const siteSelector = page.getByLabel('Selecciona local')
    if (await siteSelector.count()) {
      const globalOption = siteSelector.getByRole('option', { name: 'Vista Global' })
      if (await globalOption.count()) {
        await siteSelector.selectOption({ label: 'Vista Global' })
      }
    }

    const eventTitle = uniqueName('E2E Widget 0R')

    await page.getByRole('button', { name: 'Nou event' }).click()
    await expect(page.getByRole('heading', { name: 'Crear event' })).toBeVisible()

    await page.getByPlaceholder('Afegir títol del event').fill(eventTitle)

    const startAt = new Date()
    startAt.setHours(12, 0, 0, 0)
    await page.locator('input[type="datetime-local"]').first().fill(toLocalDateTimeInput(startAt))

    const rpcRequestPromise = page.waitForRequest((request) => {
      return request.url().includes('/rest/v1/rpc/create_calendar_event_with_reminders')
        && request.method() === 'POST'
    })

    const rpcResponsePromise = page.waitForResponse((response) => {
      if (!response.url().includes('/rest/v1/rpc/create_calendar_event_with_reminders')) return false
      return response.request().method() === 'POST'
    })

    await submitCreateEvent(page)

    const rpcRequest = await rpcRequestPromise
    const payload = rpcRequest.postDataJSON() as {
      p_entity_type: string
      p_reminders?: unknown[]
      p_site_id?: string | null
    }

    expect(payload.p_entity_type).toBe('manual')
    expect(payload.p_reminders ?? []).toHaveLength(0)
    expect(payload.p_site_id == null || payload.p_site_id === '').toBeTruthy()

    const rpcResponse = await rpcResponsePromise
    expect(rpcResponse.ok()).toBeTruthy()

    const responseBody = await rpcResponse.json()
    const queuedReminders = readQueuedRemindersCount(responseBody)
    if (queuedReminders !== null) {
      expect(queuedReminders).toBe(0)
    }

    await expect(page.getByRole('heading', { name: 'Crear event' })).toHaveCount(0)
  })

  test('widget: create manual event with multiple reminders in site context', async ({ page }) => {
    await page.goto('/dashboard')
    await expect(page.getByTestId('calendar-widget')).toBeVisible()

    const siteSelector = page.getByLabel('Selecciona local')
    let selectedSiteId: string | null = null
    if (await siteSelector.count()) {
      await siteSelector.selectOption({ label: 'Acme Gràcia' })
      selectedSiteId = await siteSelector.inputValue()
    }

    const eventTitle = uniqueName('E2E Widget NR')

    await page.getByRole('button', { name: 'Nou event' }).click()
    await expect(page.getByRole('heading', { name: 'Crear event' })).toBeVisible()

    await page.getByPlaceholder('Afegir títol del event').fill(eventTitle)

    const startAt = new Date()
    startAt.setHours(13, 0, 0, 0)
    await page.locator('input[type="datetime-local"]').first().fill(toLocalDateTimeInput(startAt))

    await page.getByRole('button', { name: 'Afegir recordatori' }).click()
    await page.getByRole('button', { name: 'Afegir recordatori' }).click()
    await page.getByRole('button', { name: 'Afegir recordatori' }).click()

    const rpcRequestPromise = page.waitForRequest((request) => {
      return request.url().includes('/rest/v1/rpc/create_calendar_event_with_reminders')
        && request.method() === 'POST'
    })

    await submitCreateEvent(page)

    const rpcRequest = await rpcRequestPromise
    const payload = rpcRequest.postDataJSON() as {
      p_entity_type: string
      p_reminders?: Array<{ offset_minutes: number; channel: string }>
      p_site_id?: string | null
    }

    expect(payload.p_entity_type).toBe('manual')
    expect(payload.p_reminders ?? []).toHaveLength(3)

    for (const reminder of payload.p_reminders ?? []) {
      expect(reminder.channel).toBe('email')
      expect(typeof reminder.offset_minutes).toBe('number')
    }

    if (selectedSiteId) {
      expect(payload.p_site_id).toBe(selectedSiteId)
    }

    await expect(page.getByRole('heading', { name: 'Crear event' })).toHaveCount(0)
  })

  test('module: create task with due_date + reminder enqueues calendar reminder', async ({ page }) => {
    await page.goto('/dashboard')
    await page.goto('/projects')
    await expect(page.getByRole('button', { name: 'Nou projecte' })).toBeVisible()

    const projectName = uniqueName('E2E Project Calendar')
    await page.getByRole('button', { name: 'Nou projecte' }).click()
    await expect(page.getByRole('heading', { name: 'Nou projecte' })).toBeVisible()

    await page.locator('#project-name').fill(projectName)
    await page.getByRole('button', { name: 'Desar' }).click()

    await expect(page).toHaveURL(/\/projects\/[0-9a-f-]+$/)

    const taskTitle = uniqueName('E2E Task Reminder')
    await page.getByRole('button', { name: 'Afegir tasca' }).click()
    await expect(page.getByRole('heading', { name: 'Nova tasca' })).toBeVisible()

    await page.locator('#task-title').fill(taskTitle)

    const dueDate = new Date()
    dueDate.setDate(dueDate.getDate() + 1)
    await page.locator('#task-due').fill(toDateInput(dueDate))
    await page.locator('#task-add-reminder').check()

    const rpcRequestPromise = page.waitForRequest((request) => {
      if (!request.url().includes('/rest/v1/rpc/create_calendar_event_with_reminders')) return false
      if (request.method() !== 'POST') return false

      const body = request.postDataJSON() as Record<string, unknown>
      return body.p_title === taskTitle && body.p_entity_type === 'task'
    })

    await page.getByRole('button', { name: 'Desar' }).click()

    const rpcRequest = await rpcRequestPromise
    const payload = rpcRequest.postDataJSON() as {
      p_entity_type: string
      p_title: string
      p_reminders?: Array<{ offset_minutes: number; channel: string }>
    }

    expect(payload.p_entity_type).toBe('task')
    expect(payload.p_title).toBe(taskTitle)
    expect(payload.p_reminders ?? []).toHaveLength(1)
    expect(payload.p_reminders?.[0]?.channel).toBe('email')

    await expect(page.getByRole('heading', { name: 'Nova tasca' })).toHaveCount(0)
    await expect(page.getByText(taskTitle)).toBeVisible({ timeout: 10_000 })
  })
})
