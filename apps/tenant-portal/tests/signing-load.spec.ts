import { expect, test } from '@playwright/test'
import { AUTH_STATE_PATH } from './e2e-users'

const SIGNING_EVENTS_PAGE_SIZE = 50

type SubmissionRow = {
  id: string
  status: 'pending' | 'in_progress' | 'completed'
  source_type: 'document_existing' | 'template_locale'
  signers: Array<{ email: string; name: string }>
  created_at: string
  last_event_at: string
}

test.describe('Signing monitoring load behavior', () => {
  test.use({ storageState: AUTH_STATE_PATH.alice })

  test.beforeEach(async ({ page }) => {
    await page.addInitScript(() => {
      sessionStorage.setItem('selectedTenantId', '10000000-0000-0000-0000-000000000001')
    })
  })

  test('Signing Center stays usable with 5k total submissions', async ({ page }) => {
    let mockedListRequestSeen = false

    const rows: SubmissionRow[] = Array.from({ length: 20 }, (_, i) => ({
      id: `sub-${i.toString().padStart(4, '0')}`,
      status: i % 3 === 0 ? 'pending' : i % 3 === 1 ? 'in_progress' : 'completed',
      source_type: i % 2 === 0 ? 'document_existing' : 'template_locale',
      signers: [{ email: `signer${i}@acme.com`, name: `Signer ${i}` }],
      created_at: new Date(Date.now() - i * 60_000).toISOString(),
      last_event_at: new Date(Date.now() - i * 30_000).toISOString(),
    }))

    await page.route('**/rest/v1/signing_submissions**', async (route) => {
      if (route.request().method() !== 'GET') {
        await route.continue()
        return
      }

      mockedListRequestSeen = true
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        headers: {
          'content-range': '0-19/5000',
        },
        body: JSON.stringify(rows),
      })
    })

    await page.goto('/documents/signing')

    await expect(page.getByRole('heading', { name: 'Centre de signatures' })).toBeVisible()
    await expect.poll(() => mockedListRequestSeen).toBeTruthy()
  })

  test('Signing detail requests paginated events', async ({ page }) => {
    const eventPageOffsetsSeen = new Set<number>()

    const submission = {
      id: 'sub-load-001',
      status: 'in_progress',
      status_reason: null,
      signers: [{ email: 'a@acme.com', name: 'Alice', status: 'pending' }],
      source_type: 'document_existing',
      created_at: new Date().toISOString(),
      submitted_at: new Date().toISOString(),
      completed_at: null,
      docuseal_submission_id: 'ds-123',
      docuseal_signing_url: null,
      error_message: null,
    }

    await page.route('**/rest/v1/signing_submissions**', async (route) => {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify(submission),
      })
    })

    await page.route('**/rest/v1/signing_events**', async (route) => {
      const url = new URL(route.request().url())
      const offsetParam = url.searchParams.get('offset')
      const limitParam = url.searchParams.get('limit')

      let from = 0
      let to = SIGNING_EVENTS_PAGE_SIZE - 1

      if (offsetParam && limitParam) {
        from = Number(offsetParam)
        to = from + Number(limitParam) - 1
      } else {
        const range = route.request().headers()['range']
        if (range) {
          const match = range.match(/(\d+)-(\d+)/)
          if (match) {
            from = Number(match[1])
            to = Number(match[2])
          }
        }
      }

      eventPageOffsetsSeen.add(from)

      const len = to - from + 1

      const events = Array.from({ length: len }, (_, idx) => {
        const eventIdx = from + idx
        return {
          id: `ev-${eventIdx}`,
          created_at: new Date(Date.now() - eventIdx * 10_000).toISOString(),
          event_source: 'system',
          event_type: `event-${eventIdx}`,
          signer_email: null,
          signer_name: null,
          status_before: eventIdx === 0 ? 'pending' : 'in_progress',
          status_after: 'in_progress',
          submission_id: 'sub-load-001',
          webhook_event_id: null,
        }
      })

      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify(events),
      })
    })

    await page.goto('/documents/signing/sub-load-001')

    await expect(page.getByRole('heading', { name: 'Detall de signatura' })).toBeVisible()
    await expect.poll(() => eventPageOffsetsSeen.has(0)).toBeTruthy()
  })
})
