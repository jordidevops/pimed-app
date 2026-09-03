import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'

export interface PdfConverterConfig {
  pdf_enabled: boolean
  native_signing_enabled: boolean
  unsigned_pdf_profile: string
  signed_pdf_profile: string
  audit_pdf_profile: string
  paper_size: string
  sync_html_max_kb: number
  timeout_ms: number
  remote_signing_token_days: number
}

const DEFAULT_CONFIG: PdfConverterConfig = {
  pdf_enabled: false,
  native_signing_enabled: false,
  unsigned_pdf_profile: 'pdf',
  signed_pdf_profile: 'pdfa2b',
  audit_pdf_profile: 'pdfa3b',
  paper_size: 'A4',
  sync_html_max_kb: 500,
  timeout_ms: 60000,
  remote_signing_token_days: 7,
}

export async function fetchPdfConverterConfig(): Promise<PdfConverterConfig> {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const { data, error } = await (supabase as any).rpc('get_pdf_converter_config')
  if (error) throw error
  const raw = (data ?? {}) as Partial<PdfConverterConfig>
  return { ...DEFAULT_CONFIG, ...raw }
}

export function usePdfConverterConfig() {
  return useQuery<PdfConverterConfig>({
    queryKey: ['pdf_converter_config'],
    queryFn: fetchPdfConverterConfig,
    staleTime: 5 * 60 * 1000, // 5 minuts
    gcTime: 10 * 60 * 1000,
  })
}
