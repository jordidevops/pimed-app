import { supabase } from '@/lib/supabase'

/** HR email first, then portal account email via RPC (G6.8). */
export async function resolveEmployeeSignerEmail(
  employeeId: string,
  preferredEmail?: string | null,
): Promise<string | null> {
  const direct = preferredEmail?.trim()
  if (direct) return direct

  const { data, error } = await supabase.rpc('resolve_employee_signer_email' as never, {
    p_employee_id: employeeId,
  } as never)

  if (error) throw new Error(error.message)
  const resolved = typeof data === 'string' ? data.trim() : ''
  return resolved || null
}

export function resolveManagerSignerEmail(accountEmail?: string | null): string | null {
  const email = accountEmail?.trim()
  return email || null
}

export function signerEmailRequiredMessage(context: 'protocol' | 'monthly_report'): string {
  if (context === 'protocol') {
    return "Cal un correu a la fitxa de l'empleat o al seu compte d'usuari per iniciar la signatura del protocol."
  }
  return "Cal un correu a la fitxa de l'empleat o al seu compte d'usuari per iniciar la signatura del registre mensual."
}
