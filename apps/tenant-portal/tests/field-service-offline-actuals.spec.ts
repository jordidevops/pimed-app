import { expect, test } from '@playwright/test'
import { AUTH_STATE_PATH, EHR_FIXTURES } from './e2e-users'

const PROJECT_ID = '51000000-0000-0000-0000-000000000101'

test.describe('CF-16 offline actuals', () => {
  test.use({ storageState: AUTH_STATE_PATH.alice })

  test('rehydrates and drains actuals/material before close-out on reconnect', async ({
    page,
    context,
  }) => {
    await page.addInitScript((tenantId: string) => {
      sessionStorage.setItem('selectedTenantId', tenantId)
      Object.defineProperty(navigator, 'onLine', {
        configurable: true,
        get: () => localStorage.getItem('cf16-e2e-offline') !== '1',
      })
    }, EHR_FIXTURES.voltTenantId)

    const commercialIssueBodies: string[] = []
    page.on('request', (request) => {
      if (request.url().includes('/rpc/issue_commercial_document')) {
        commercialIssueBodies.push(request.postData() ?? '')
      }
    })

    await page.goto(`/field/orders/${PROJECT_ID}?tab=do`)
    await expect(page.getByRole('heading').first()).toBeVisible({ timeout: 25_000 })

    await page.evaluate(() => localStorage.setItem('cf16-e2e-offline', '1'))
    const offlineApi = async (route: import('@playwright/test').Route) => {
      await route.abort('internetdisconnected')
    }
    await context.route('http://127.0.0.1:54321/**', offlineApi)
    const ids = await page.evaluate(
      async ({ tenantId, projectId }) => {
        const db = await new Promise<IDBDatabase>((resolve, reject) => {
          const request = indexedDB.open('field_ops_v1')
          request.onsuccess = () => resolve(request.result)
          request.onerror = () => reject(request.error)
        })
        const lineId = crypto.randomUUID()
        const materialId = crypto.randomUUID()
        const closeId = crypto.randomUUID()
        const tx = db.transaction('operations', 'readwrite')
        const store = tx.objectStore('operations')
        const base = {
          tenant_id: tenantId,
          project_id: projectId,
          status: 'pending',
          retry_count: 0,
        }
        store.add({
          ...base,
          id: lineId,
          kind: 'project_line.actual',
          created_at: new Date().toISOString(),
          payload: { project_id: projectId, unit: 'km', quantity: 12.5 },
        })
        store.add({
          ...base,
          id: materialId,
          kind: 'project_material.add',
          created_at: new Date(Date.now() + 1).toISOString(),
          payload: {
            project_id: projectId,
            name: 'CF-16 E2E cable',
            quantity: 2,
            unit: 'm',
          },
        })
        store.add({
          ...base,
          id: closeId,
          kind: 'project.close_out',
          created_at: new Date(Date.now() + 2).toISOString(),
          depends_on: [lineId, materialId],
          payload: { project_id: projectId },
        })
        await new Promise<void>((resolve, reject) => {
          tx.oncomplete = () => resolve()
          tx.onerror = () => reject(tx.error)
        })
        db.close()
        window.dispatchEvent(new CustomEvent('fieldop:changed'))
        return { lineId, materialId, closeId }
      },
      { tenantId: EHR_FIXTURES.voltTenantId, projectId: PROJECT_ID },
    )

    await page.reload({ waitUntil: 'domcontentloaded' })
    const durableIds = await page.evaluate(async () => {
      const db = await new Promise<IDBDatabase>((resolve, reject) => {
        const request = indexedDB.open('field_ops_v1')
        request.onsuccess = () => resolve(request.result)
        request.onerror = () => reject(request.error)
      })
      const tx = db.transaction('operations', 'readonly')
      const rows = await new Promise<Array<{ id: string }>>((resolve, reject) => {
        const request = tx.objectStore('operations').getAll()
        request.onsuccess = () => resolve(request.result)
        request.onerror = () => reject(request.error)
      })
      db.close()
      return rows.map((row) => row.id)
    })
    expect(durableIds).toEqual(expect.arrayContaining(Object.values(ids)))

    await context.unroute('http://127.0.0.1:54321/**', offlineApi)
    const syncBatches: string[][] = []
    await context.route('**/rest/v1/rpc/sync_field_ops', async (route) => {
      const body = route.request().postDataJSON() as {
        p_batch?: Array<{ id: string }>
      }
      syncBatches.push((body.p_batch ?? []).map((op) => op.id))
      await route.fulfill({
        contentType: 'application/json',
        body: JSON.stringify(
          (body.p_batch ?? []).map((op) => ({
            client_op_id: op.id,
            status: 'synced',
            server_id: op.id,
            message: null,
          })),
        ),
      })
    })
    await page.evaluate(() => localStorage.removeItem('cf16-e2e-offline'))
    await page.reload({ waitUntil: 'domcontentloaded' })
    await expect
      .poll(() => syncBatches.flat().includes(ids.closeId), { timeout: 15_000 })
      .toBe(true)

    const flattened = syncBatches.flat()
    expect(flattened.indexOf(ids.lineId)).toBeGreaterThanOrEqual(0)
    expect(flattened.indexOf(ids.materialId)).toBeGreaterThanOrEqual(0)
    expect(flattened.indexOf(ids.closeId)).toBeGreaterThan(flattened.indexOf(ids.lineId))
    expect(flattened.indexOf(ids.closeId)).toBeGreaterThan(flattened.indexOf(ids.materialId))

    await expect
      .poll(async () => {
        return page.evaluate(async (expectedIds) => {
          const db = await new Promise<IDBDatabase>((resolve, reject) => {
            const request = indexedDB.open('field_ops_v1')
            request.onsuccess = () => resolve(request.result)
            request.onerror = () => reject(request.error)
          })
          const tx = db.transaction('operations', 'readonly')
          const rows = await new Promise<Array<{ id: string; status: string }>>(
            (resolve, reject) => {
              const request = tx.objectStore('operations').getAll()
              request.onsuccess = () => resolve(request.result)
              request.onerror = () => reject(request.error)
            },
          )
          db.close()
          const byId = new Map(rows.map((row) => [row.id, row.status]))
          return expectedIds.every((id) => byId.get(id) === 'synced')
        }, Object.values(ids))
      }, { timeout: 15_000 })
      .toBe(true)

    expect(
      commercialIssueBodies.some((body) => body.includes('delivery_note')),
    ).toBe(false)
  })
})
