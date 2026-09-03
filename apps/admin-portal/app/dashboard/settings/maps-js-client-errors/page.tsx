import { getT } from '@/lib/i18n/server'
import { getMapsJsClientErrorsSummary } from '@/app/admin/actions/maps-js-client-errors'

export default async function MapsJsClientErrorsPage() {
  const t = getT('settings')
  const rows = await getMapsJsClientErrorsSummary(200)

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-gray-900">
          {t('settings.maps_js_client_errors.title', 'Maps JS client errors')}
        </h1>
        <p className="text-gray-500 mt-1 text-sm max-w-2xl">
          {t(
            'settings.maps_js_client_errors.description',
            'Per tenant: category/code/origin with first/last timestamps and counter.',
          )}
        </p>
      </div>

      <div className="rounded-lg border border-gray-200 bg-white overflow-hidden">
        <div className="overflow-x-auto">
          <table className="min-w-full text-sm">
            <thead className="bg-gray-50 border-b border-gray-200">
              <tr>
                <th className="text-left py-3 px-4 font-medium text-gray-600">Tenant</th>
                <th className="text-left py-3 px-4 font-medium text-gray-600">Category</th>
                <th className="text-left py-3 px-4 font-medium text-gray-600">Code</th>
                <th className="text-left py-3 px-4 font-medium text-gray-600">Origin</th>
                <th className="text-left py-3 px-4 font-medium text-gray-600">First</th>
                <th className="text-left py-3 px-4 font-medium text-gray-600">Last</th>
                <th className="text-left py-3 px-4 font-medium text-gray-600">Count</th>
              </tr>
            </thead>
            <tbody>
              {rows.length === 0 ? (
                <tr>
                  <td colSpan={7} className="py-10 px-4 text-gray-500">
                    {t('settings.maps_js_client_errors.empty', 'No client errors recorded yet.')}
                  </td>
                </tr>
              ) : (
                rows.map((r, idx) => (
                  <tr key={`${r.tenant_id}-${r.category}-${r.code}-${r.origin}-${idx}`} className="border-b border-gray-100">
                    <td className="py-2 px-4">{r.tenant_name ?? r.tenant_id}</td>
                    <td className="py-2 px-4">{r.category}</td>
                    <td className="py-2 px-4">{r.code}</td>
                    <td className="py-2 px-4">{r.origin}</td>
                    <td className="py-2 px-4">{r.first_seen_at.slice(0, 19).replace('T', ' ')}</td>
                    <td className="py-2 px-4">{r.last_seen_at.slice(0, 19).replace('T', ' ')}</td>
                    <td className="py-2 px-4 font-medium">{r.count}</td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  )
}

