/**
 * Contracte canònic per connectors de nòmina (spike D3).
 * Font de dades: api.export_payroll_period → PayrollExportPayload.
 */

export type PayrollConnectorId = 'generic_csv' | 'a3_variables' | 'sage_concepts' | 'csv_custom'

export type PayrollExportSourceMode = 'daily' | 'aggregate'

export type PayrollExportOutputFormat = 'csv' | 'xlsx'

/** Camps disponibles per mapping (diari). */
export const PAYROLL_DAILY_SOURCE_FIELDS = [
  'employee_id',
  'employee_name',
  'document_id',
  'work_date',
  'day_type',
  'expected_minutes',
  'worked_minutes',
  'net_minutes',
  'presence_minutes',
  'work_minutes',
  'travel_minutes',
  'effective_minutes',
  'paid_minutes',
  'overtime_authorized_minutes',
  'consolidation_needs_review',
  'work_profile',
  'work_day_type',
  'allowances',
  'overtime_minutes',
  'is_laborable',
  'holiday_name',
  'punch_count',
  'remote_punch_count',
  'entry_status',
  'summary_status',
  'needs_review',
  'payroll_locked',
  'is_it',
  'absence_type',
  'absence_type_name',
  'absence_export_code',
  'absence_parent_key',
  'absence_subtype_key',
  'absence_status',
  'absence_is_paid',
  'partial_start_time',
  'partial_end_time',
  'partial_hours',
  'payroll_action',
  'anomaly_codes',
  'compensation_balance_minutes',
] as const

export const PAYROLL_DAILY_EFFECTIVE_FIELDS = [
  'presence_minutes',
  'net_minutes',
  'work_minutes',
  'travel_minutes',
  'effective_minutes',
  'paid_minutes',
  'overtime_authorized_minutes',
  'consolidation_needs_review',
  'work_profile',
  'work_day_type',
] as const

export type PayrollDailySourceField = (typeof PAYROLL_DAILY_SOURCE_FIELDS)[number]

/** Camps disponibles per mapping (agregat per empleat). */
export const PAYROLL_AGGREGATE_SOURCE_FIELDS = [
  'employee_id',
  'employee_name',
  'document_id',
  'period_from',
  'period_to',
  'total_expected_minutes',
  'total_worked_minutes',
  'total_presence_minutes',
  'total_work_minutes',
  'total_travel_minutes',
  'total_effective_minutes',
  'total_paid_minutes',
  'total_overtime_minutes',
  'total_overtime_authorized_minutes',
  'laborable_days',
  'worked_days',
  'absence_days',
  'it_days',
  'missing_punch_days',
  'draft_days',
  'approved_days',
  'exported_days',
  'remote_punch_days',
  'compensation_balance_minutes',
] as const

export const PAYROLL_AGGREGATE_EFFECTIVE_FIELDS = [
  'total_presence_minutes',
  'total_work_minutes',
  'total_travel_minutes',
  'total_effective_minutes',
  'total_paid_minutes',
  'total_overtime_authorized_minutes',
] as const

export type PayrollAggregateSourceField = (typeof PAYROLL_AGGREGATE_SOURCE_FIELDS)[number]

export type PayrollConceptUnit = 'hours' | 'days' | 'minutes' | 'amount'

/** Concepte de nòmina extern (codi A3/Sage) lligat a dades nostres. */
export interface PayrollConceptMapping {
  concept_key: string
  external_code: string
  unit: PayrollConceptUnit
  source_field?: PayrollDailySourceField | PayrollAggregateSourceField
  absence_type?: string
  label?: string
}

export type PayrollColumnFormat = 'text' | 'date_dd_mm_yyyy' | 'hours_hh_mm' | 'minutes_decimal' | 'boolean_01'

/** Una columna del fitxer destí. */
export interface PayrollExportColumnMapping {
  header: string
  source?: PayrollDailySourceField | PayrollAggregateSourceField
  concept_key?: string
  literal?: string
  format?: PayrollColumnFormat
}

export interface PayrollExportProfileMapping {
  columns: PayrollExportColumnMapping[]
  concepts?: PayrollConceptMapping[]
  header_row?: number
  csv_delimiter?: string
}

/** Perfil d'exportació (futur: taula payroll_export_profiles). */
export interface PayrollExportProfile {
  id: string
  tenant_id: string
  name: string
  connector: PayrollConnectorId
  source_mode: PayrollExportSourceMode
  output_format: PayrollExportOutputFormat
  mapping: PayrollExportProfileMapping
  is_active: boolean
}

export const EXAMPLE_A3_AGGREGATE_PROFILE: Omit<PayrollExportProfile, 'id' | 'tenant_id'> = {
  name: 'A3 — conceptes variables (agregat mensual)',
  connector: 'a3_variables',
  source_mode: 'aggregate',
  output_format: 'csv',
  is_active: true,
  mapping: {
    header_row: 1,
    csv_delimiter: ';',
    columns: [
      { header: 'NIF', source: 'document_id' },
      { header: 'Nombre', source: 'employee_name' },
      { header: 'PeriodoDesde', source: 'period_from', format: 'date_dd_mm_yyyy' },
      { header: 'PeriodoHasta', source: 'period_to', format: 'date_dd_mm_yyyy' },
      { header: 'HorasExtra', concept_key: 'overtime_hours', format: 'hours_hh_mm' },
      { header: 'DiasIT', concept_key: 'it_day' },
    ],
    concepts: [
      {
        concept_key: 'overtime_hours',
        external_code: 'HEX',
        unit: 'hours',
        source_field: 'total_overtime_minutes',
        label: 'Hores extra (configurar codi al conveni)',
      },
      {
        concept_key: 'it_day',
        external_code: 'IT',
        unit: 'days',
        source_field: 'it_days',
        label: 'Dies IT',
      },
    ],
  },
}

export const EXAMPLE_SAGE_AGGREGATE_PROFILE: Omit<PayrollExportProfile, 'id' | 'tenant_id'> = {
  name: 'Sage — conceptos salariales masivos (agregat)',
  connector: 'sage_concepts',
  source_mode: 'aggregate',
  output_format: 'csv',
  is_active: true,
  mapping: {
    header_row: 1,
    csv_delimiter: ';',
    columns: [
      { header: 'CodigoEmpleado', source: 'document_id' },
      { header: 'Empleado', source: 'employee_name' },
      { header: 'Mes', source: 'period_from', format: 'date_dd_mm_yyyy' },
      { header: 'CuantiaHorasExtra', concept_key: 'overtime_hours', format: 'minutes_decimal' },
      { header: 'DiasAbsentismoIT', concept_key: 'it_day' },
    ],
    concepts: [
      {
        concept_key: 'overtime_hours',
        external_code: 'CONCEPTO_HEX',
        unit: 'minutes',
        source_field: 'total_overtime_minutes',
        label: 'Substituir pel codi Sage de l’empresa',
      },
      {
        concept_key: 'it_day',
        external_code: 'CONCEPTO_IT',
        unit: 'days',
        source_field: 'it_days',
      },
    ],
  },
}
