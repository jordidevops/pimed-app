import { describe, expect, it } from 'vitest'
import {
  PORTAL_LABEL_CSV_DELIMITER,
  PORTAL_LABEL_CSV_HEADERS,
  buildPortalLabelCsv,
  escapePortalLabelCsvCell,
} from './portalLabelExport'

describe('portalLabelExport', () => {
  it('escapa cometes dins de cel·les CSV', () => {
    expect(escapePortalLabelCsvCell('Anna "Ana" Garcia')).toBe('"Anna ""Ana"" Garcia"')
  })

  it('genera CSV amb BOM-friendly delimiter per Excel ca/ES', () => {
    const csv = buildPortalLabelCsv([
      {
        employeeName: 'Anna Garcia',
        employeeCode: 'EMP001',
        portalUrl: 'https://demo.public.example/e/secret',
        label: 'WhatsApp',
      },
    ])

    const lines = csv.split('\r\n')
    expect(lines[0]).toBe(
      PORTAL_LABEL_CSV_HEADERS.map((h) => `"${h}"`).join(PORTAL_LABEL_CSV_DELIMITER),
    )
    expect(lines[1]).toBe(
      [
        '"Anna Garcia"',
        '"EMP001"',
        '"https://demo.public.example/e/secret"',
        '"https://demo.public.example/e/secret"',
        '"WhatsApp"',
      ].join(PORTAL_LABEL_CSV_DELIMITER),
    )
  })

  it('escapa noms amb comes i URLs amb query', () => {
    const csv = buildPortalLabelCsv([
      {
        employeeName: 'Garcia, Anna',
        employeeCode: '',
        portalUrl: 'https://demo.example/e/x?ref=1',
        label: 'QR vestuari',
      },
    ])

    expect(csv).toContain('"Garcia, Anna"')
    expect(csv).toContain('"https://demo.example/e/x?ref=1"')
  })
})
