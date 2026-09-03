/**
 * generate-attendance-report
 * Genera export JSON del registre mensual (base per PDF/signatura).
 */
import { corsHeaders } from '../_shared/cors.ts'
import { createAdminClient } from '../_shared/supabase.ts'

const SERVICE_ROLE_KEY =
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || Deno.env.get('SERVICE_ROLE_KEY') || ''

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'method_not_allowed' }), {
      status: 405,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }

  const authHeader = req.headers.get('Authorization') ?? ''
  const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : ''
  if (!token || token !== SERVICE_ROLE_KEY) {
    return new Response('Unauthorized', { status: 401, headers: corsHeaders })
  }

  const body = await req.json().catch(() => ({}))
  const { employee_id, year, month, tenant_id } = body as {
    employee_id?: string
    year?: number
    month?: number
    tenant_id?: string
  }

  if (!employee_id || !year || !month) {
    return new Response(JSON.stringify({ error: 'missing_params' }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }

  const db = createAdminClient()
  const { data: report, error } = await db.rpc('export_attendance_month', {
    p_employee_id: employee_id,
    p_year: year,
    p_month: month,
  })

  if (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }

  const contentHash = await crypto.subtle.digest(
    'SHA-256',
    new TextEncoder().encode(JSON.stringify(report)),
  )
  const hashHex = [...new Uint8Array(contentHash)].map((b) => b.toString(16).padStart(2, '0')).join('')

  if (tenant_id) {
    try {
      await db.rpc('upsert_attendance_monthly_report_draft', {
        p_tenant_id: tenant_id,
        p_employee_id: employee_id,
        p_year: year,
        p_month: month,
        p_content_hash: hashHex,
      })
    } catch {
      // best-effort
    }
  }

  return new Response(JSON.stringify({ report, content_hash: hashHex }), {
    status: 200,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
})
