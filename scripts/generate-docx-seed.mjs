#!/usr/bin/env node
/**
 * generate-docx-seed.mjs
 *
 * Genera els DOCX de plataforma RRHH/legal/… i, al final, crida
 * generate-commercial-docx-seed.mjs (pressupost/albarà).
 *
 * Ús i moment (després de db reset): veure scripts/README.md
 *   cd scripts && npm install && node generate-docx-seed.mjs
 *
 * El JWT service_role es llegeix de SUPABASE_SERVICE_ROLE_KEY o de `supabase status`.
 * El JWT secret (hex) no serveix — Storage respon Invalid Compact JWS.
 */

import {
  Document, Packer,
  Paragraph, TextRun, HeadingLevel,
  Table, TableRow, TableCell, WidthType,
} from 'docx'
import { writeFile, mkdir } from 'node:fs/promises'
import { existsSync }        from 'node:fs'
import path                  from 'node:path'
import { fileURLToPath }     from 'node:url'
import { loadServiceRoleJwt } from './load-service-role-jwt.mjs'

const __dirname = path.dirname(fileURLToPath(import.meta.url))

// ─── Config ───────────────────────────────────────────────────────────────────
const SUPABASE_URL     = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321'
const SERVICE_ROLE_KEY = loadServiceRoleJwt()
const BUCKET           = 'document-templates'
const DOCX_MIME        = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
const CREATOR_PLATFORM = '20000000-0000-0000-0000-000000000001'
const CREATOR_ACME     = '20000000-0000-0000-0000-000000000002'
const TENANT_ACME      = '10000000-0000-0000-0000-000000000001'

// ─── docx builder helpers ─────────────────────────────────────────────────────

/** Text normal */
const T  = (text) => new TextRun(text)
/** Text en negreta */
const B  = (text) => new TextRun({ text, bold: true })
/** Placeholder de variable [[key]] — blau i negreta perquè DocuSeal els distingeixi */
const V  = (key)  => new TextRun({ text: `[[${key}]]`, bold: true, color: '1D4ED8' })
/** Camp interactiu DocuSeal (signatura, data, text…) — morat per distingir-lo del contingut */
const F  = (name, type, role) => new TextRun({ text: `{{${name};type=${type};role=${role}}}`, bold: true, color: '7C3AED' })
/** Paràgraf amb fills */
const P  = (...children) => new Paragraph({ children })
/** Paràgraf buit */
const BR = () => new Paragraph({ text: '' })
/** Títol H1 */
const H1 = (text) => new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun({ text, bold: true })] })
/** Títol H2 */
const H2 = (text) => new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun(text)] })

/** Fila de dues columnes [Etiqueta, Variable] per a taules de dades */
function dataRow(label, varKey) {
  return new TableRow({
    children: [
      new TableCell({
        width: { size: 2800, type: WidthType.DXA },
        children: [new Paragraph({ children: [new TextRun(label)] })],
      }),
      new TableCell({
        width: { size: 6200, type: WidthType.DXA },
        children: [new Paragraph({ children: [V(varKey)] })],
      }),
    ],
  })
}

/** Taula de dades a partir de parelles [etiqueta, clauVar] */
function infoTable(rows) {
  return new Table({
    width: { size: 9000, type: WidthType.DXA },
    rows: rows.map(([label, key]) => dataRow(label, key)),
  })
}

/** Fila de taula amb capçalera [Etiqueta (negreta), Variable] */
function reportHeaderRow(col1, col2) {
  return new TableRow({
    children: [
      new TableCell({
        width: { size: 2800, type: WidthType.DXA },
        children: [new Paragraph({ children: [new TextRun({ text: col1, bold: true })] })],
      }),
      new TableCell({
        width: { size: 6200, type: WidthType.DXA },
        children: [new Paragraph({ children: [new TextRun({ text: col2, bold: true })] })],
      }),
    ],
  })
}

/** Secció de signatures estàndard al peu del document */
const SIGN_SECTION = () => [
  BR(),
  BR(),
  P(T('─────────────────────────────────────────────────────────────────────────')),
  P(T('Lloc i data: ___________________________________')),
  BR(),
  P(B('Signatura empresa:'), T('  ______________________________     '), B('Signatura treballador/a:'), T('  ______________________________')),
]

// QT-6 commercial full-body DOCX helpers (linesTable / totalsBlock / acceptRejectBlock)
// live in generate-commercial-docx-seed.mjs so this HR seed is not rewritten.

// ─── Definicions de les plantilles (001-028) ─────────────────────────────────

const TEMPLATES = [

  // ── 01 Contracte de Treball Indefinit ─────────────────────────────────────
  {
    id:      '72000000-0000-0000-0000-000000000001',
    localeId:'73000000-0000-0000-0000-000000000001',
    name:         'Contracte de treball indefinit',
    description:  'Contracte estàndard per a noves incorporacions.',
    category:     'hr',
    tenantId:     null,
    isPlatformDefault: true,
    createdBy:    CREATOR_PLATFORM,
    storagePath:  'platform/docx/01-contracte-treball-indefinit-ca.docx',
    variablesSchema: {
      full_name:     { type: 'string', label: "Nom del treballador/a",   required: true,  role: 'worker', order: 0 },
      document_id:   { type: 'string', label: 'DNI/NIE',                 required: true,  role: 'worker', order: 1 },
      job_title:     { type: 'string', label: 'Càrrec',                  required: true,  role: 'worker', order: 2 },
      data_inici:    { type: 'date',   label: "Data d'incorporació",     required: true,                       order: 3 },
      salari_anual:  { type: 'number', label: 'Salari brut anual (EUR)', required: true,                       order: 4 },
      jornada_hores: { type: 'number', label: 'Hores setmanals',         required: true,                       order: 5 },
    },
    signingRolesSchema: {
      worker:      { entity_type: 'employee', label: "Treballador/a",    order: 0, for_signing: true },
      hr_manager: { entity_type: 'employee', label: 'Responsable RRHH', order: 1, for_signing: true },
    },
    sampleValues: { full_name: 'Maria Garcia Lopez', document_id: '12345678A', job_title: "Tècnic/a", data_inici: '2025-09-01', salari_anual: '28000', jornada_hores: '40' },
    children: () => [
      H1('Contracte de Treball Indefinit'),
      BR(),
      P(T("Entre l'empresa "), B('Acme Corp S.A.'), T(", amb CIF B-12345678, d'una banda, i el/la treballador/a de l'altra:")),
      BR(),
      infoTable([
        ["Nom complet",              "full_name"],
        ["DNI / NIE",                "document_id"],
        ["Càrrec / Lloc de treball", "job_title"],
      ]),
      BR(),
      H2("Condicions de la contractació"),
      infoTable([
        ["Data d'incorporació",      "data_inici"],
        ["Salari brut anual (EUR)",  "salari_anual"],
        ["Jornada (h/setmana)",      "jornada_hores"],
      ]),
      BR(),
      P(T("Ambdues parts signen el present contracte de mutu acord, en compliment de la legislació laboral vigent i de les disposicions del conveni col·lectiu aplicable.")),
      ...SIGN_SECTION(),
    ],
  },

  // ── 02 Sol·licitud de Vacances ─────────────────────────────────────────────
  {
    id:      '72000000-0000-0000-0000-000000000002',
    localeId:'73000000-0000-0000-0000-000000000002',
    name:         "Sol·licitud de vacances",
    description:  'Formulari de sol·licitud de vacances anuals.',
    category:     'hr',
    tenantId:     null,
    isPlatformDefault: true,
    createdBy:    CREATOR_PLATFORM,
    storagePath:  'platform/docx/02-sollicitud-vacances-ca.docx',
    variablesSchema: {
      full_name:  { type: 'string', label: "Nom del treballador/a",  required: true,  role: 'worker', order: 0 },
      data_inici: { type: 'date',   label: 'Data inici vacances',    required: true,                       order: 1 },
      data_fi:    { type: 'date',   label: 'Data fi vacances',       required: true,                       order: 2 },
      dies:       { type: 'number', label: 'Dies laborables',        required: true,                       order: 3 },
      data_sol:   { type: 'date',   label: 'Data de la sol·licitud', required: true,                       order: 4 },
    },
    signingRolesSchema: {
      worker:  { entity_type: 'employee', label: "Treballador/a", order: 0, for_signing: true },
      direct_manager: { entity_type: 'employee', label: "Cap immediat",  order: 1, for_signing: true },
    },
    sampleValues: { full_name: 'Marc Vila Bosch', data_inici: '2025-08-01', data_fi: '2025-08-15', dies: '11', data_sol: '2025-06-15' },
    children: () => [
      H1("Sol·licitud de Vacances"),
      BR(),
      P(T("El/la treballador/a "), V("full_name"), T(" sol·licita gaudir del dret de vacances anuals remunerades:")),
      BR(),
      infoTable([
        ["Data d'inici",             "data_inici"],
        ["Data de fi",               "data_fi"],
        ["Dies laborables",          "dies"],
        ["Data de la sol·licitud",   "data_sol"],
      ]),
      BR(),
      P(T("La present sol·licitud queda subjecta a l'aprovació del/la cap immediat/a i a les necessitats organitzatives de l'empresa.")),
      ...SIGN_SECTION(),
    ],
  },

  // ── 03 Sol·licitud de Canvi de Jornada ────────────────────────────────────
  {
    id:      '72000000-0000-0000-0000-000000000003',
    localeId:'73000000-0000-0000-0000-000000000003',
    name:         'Sol·licitud canvi de jornada',
    description:  'Petició formal de canvi de distribució horària.',
    category:     'hr',
    tenantId:     null,
    isPlatformDefault: true,
    createdBy:    CREATOR_PLATFORM,
    storagePath:  'platform/docx/03-sollicitud-canvi-jornada-ca.docx',
    variablesSchema: {
      full_name:    { type: 'string', label: "Nom del treballador/a",    required: true,  role: 'worker', order: 0 },
      nova_jornada: { type: 'number', label: 'Nova jornada (h/setmana)', required: true,                       order: 1 },
      motiu:        { type: 'string', label: 'Motiu de la petició',      required: true,                       order: 2 },
      data_efecte:  { type: 'date',   label: "Data d'efecte",            required: true,                       order: 3 },
    },
    signingRolesSchema: {
      worker:      { entity_type: 'employee', label: "Treballador/a",    order: 0, for_signing: true },
      hr_manager: { entity_type: 'employee', label: 'Responsable RRHH', order: 1, for_signing: true },
    },
    sampleValues: { full_name: 'Laia Torres Serra', nova_jornada: '32', motiu: 'Conciliació familiar', data_efecte: '2025-10-01' },
    children: () => [
      H1("Sol·licitud de Canvi de Jornada"),
      BR(),
      P(T("El/la treballador/a "), V("full_name"), T(" sol·licita formalment la modificació de la seva jornada laboral:")),
      BR(),
      infoTable([
        ["Nova jornada (h/setmana)",  "nova_jornada"],
        ["Motiu de la petició",       "motiu"],
        ["Data d'efecte",             "data_efecte"],
      ]),
      BR(),
      P(T("Aquesta modificació quedarà formalitzada com a annex al contracte de treball vigent un cop signada per ambdues parts.")),
      ...SIGN_SECTION(),
    ],
  },

  // ── 04 Acta de Lliurament d'EPI (schema-based, full_name amb role) ─────────
  {
    id:      '72000000-0000-0000-0000-000000000004',
    localeId:'73000000-0000-0000-0000-000000000004',
    name:         "Acta de lliurament d'EPI",
    description:  "Acta de recepció d'equips de protecció individual.",
    category:     'safety',
    tenantId:     null,
    isPlatformDefault: true,
    createdBy:    CREATOR_PLATFORM,
    storagePath:  'platform/docx/04-acta-lliurament-epi-ca.docx',
    variablesSchema: {
      full_name:       { type: 'string', label: "Nom del treballador/a", required: true,  role: 'worker', order: 0 },
      data_lliurament: { type: 'date',   label: 'Data de lliurament',    required: true,                       order: 1 },
      llista_epi:      { type: 'string', label: 'EPI lliurats',          required: true,                       order: 2 },
    },
    signingRolesSchema: {
      worker: { entity_type: 'employee', label: "Treballador/a",    order: 0, for_signing: true },
      safety_supervisor:  { entity_type: 'employee', label: "Supervisor/a PRL", order: 1, for_signing: true },
    },
    sampleValues: { full_name: 'Joan Puig Ferrer', data_lliurament: '2025-07-01', llista_epi: 'Casc, guants, ulleres, botes de seguretat' },
    children: () => [
      H1("Acta de Lliurament d'Equips de Protecció Individual (EPI)"),
      BR(),
      P(T("En compliment de la normativa de prevenció de riscos laborals (Llei 31/1995), es fa constar el lliurament dels EPI indicats:")),
      BR(),
      infoTable([
        ["Treballador/a",           "full_name"],
        ["Data de lliurament",      "data_lliurament"],
        ["EPI lliurats",            "llista_epi"],
      ]),
      BR(),
      P(T("El/la treballador/a declara haver rebut els EPI en perfecte estat i es compromet a:")),
      P(T("  • Usar-los correctament en totes les tasques que ho requereixin.")),
      P(T("  • Mantenir-los en bon estat i comunicar qualsevol deteriorament o mal funcionament.")),
      P(T("  • Retornar-los en cas de cessament o canvi de lloc de treball.")),
      ...SIGN_SECTION(),
    ],
  },

  // ── 05 Declaració de Confidencialitat (schema-based, full_name amb role) ───
  {
    id:      '72000000-0000-0000-0000-000000000005',
    localeId:'73000000-0000-0000-0000-000000000005',
    name:         'Declaració de confidencialitat',
    description:  'Acord de confidencialitat i no-divulgació.',
    category:     'legal',
    tenantId:     null,
    isPlatformDefault: true,
    createdBy:    CREATOR_PLATFORM,
    storagePath:  'platform/docx/05-declaracio-confidencialitat-ca.docx',
    variablesSchema: {
      full_name: { type: 'string', label: "Nom del treballador/a", required: true,  role: 'worker', order: 0 },
      data:      { type: 'date',   label: 'Data de signatura',     required: true,                       order: 1 },
    },
    signingRolesSchema: {
      worker: { entity_type: 'employee', label: "Treballador/a", order: 0, for_signing: true },
    },
    sampleValues: { full_name: 'Anna Soler Mas', data: '2025-07-15' },
    children: () => [
      H1("Declaració de Confidencialitat i No-Divulgació"),
      BR(),
      P(T("Jo, "), V("full_name"), T(", declaro i em comprometo formalment a:")),
      BR(),
      P(T("1. Mantenir en estricta confidencialitat tota la informació de caràcter reservat, tècnic, comercial, estratègic o personal a la qual accedeixi en l'exercici de les meves funcions.")),
      BR(),
      P(T("2. No divulgar, reproduir ni transmetre cap informació confidencial a tercers sense autorització expressa per escrit de l'empresa.")),
      BR(),
      P(T("3. Complir aquesta obligació tant durant la vigència de la relació laboral com indefinidament un cop extingida.")),
      BR(),
      P(T("4. Notificar immediatament a l'empresa qualsevol bretxa de confidencialitat de la qual tingui coneixement.")),
      BR(),
      P(T("Data de signatura: "), V("data")),
      ...SIGN_SECTION(),
    ],
  },

  // ── 06 Sol·licitud d'Avançament Salarial (schema-based, full_name amb role) ─
  {
    id:      '72000000-0000-0000-0000-000000000006',
    localeId:'73000000-0000-0000-0000-000000000006',
    name:         "Sol·licitud d'avançament salarial",
    description:  "Petició d'avançament sobre nòmina futura.",
    category:     'hr',
    tenantId:     null,
    isPlatformDefault: true,
    createdBy:    CREATOR_PLATFORM,
    storagePath:  'platform/docx/06-sollicitud-avancament-salarial-ca.docx',
    variablesSchema: {
      full_name:  { type: 'string', label: "Nom del treballador/a",   required: true,  role: 'worker', order: 0 },
      import_sol: { type: 'number', label: 'Import sol·licitat (EUR)', required: true,                       order: 1 },
      motiu:      { type: 'string', label: 'Motiu',                   required: false,                       order: 2 },
    },
    signingRolesSchema: {
      worker:      { entity_type: 'employee', label: "Treballador/a",    order: 0, for_signing: true },
      hr_director: { entity_type: 'employee', label: 'Director/a RRHH', order: 1, for_signing: true },
    },
    sampleValues: { full_name: 'Marc Vila Bosch', import_sol: '500', motiu: 'Despeses mèdiques imprevistes' },
    children: () => [
      H1("Sol·licitud d'Avançament de Nòmina"),
      BR(),
      P(T("El/la treballador/a "), V("full_name"), T(" sol·licita un avançament sobre la propera nòmina:")),
      BR(),
      infoTable([
        ["Import sol·licitat (EUR)", "import_sol"],
        ["Motiu",                    "motiu"],
      ]),
      BR(),
      P(T("L'import avançat es descomptarà íntegrament de la nòmina del mes en curs o del mes immediatament posterior, previ acord entre les parts.")),
      BR(),
      P(T("El/la treballador/a reconeix i accepta expressament el descompte corresponent.")),
      ...SIGN_SECTION(),
    ],
  },

  // ── 07 Butlletí d'Acollida ─────────────────────────────────────────────────
  {
    id:      '72000000-0000-0000-0000-000000000007',
    localeId:'73000000-0000-0000-0000-000000000007',
    name:         "Butlletí d'acollida",
    description:  'Document informatiu per a nous treballadors (generar i lliurar).',
    category:     'hr',
    tenantId:     null,
    isPlatformDefault: true,
    createdBy:    CREATOR_PLATFORM,
    storagePath:  'platform/docx/07-butlleti-acollida-ca.docx',
    variablesSchema: {
      nom_treballador:      { type: 'string', label: "Nom del treballador/a",    required: true,  order: 0 },
      data_incorporacio:   { type: 'date',   label: "Data d'incorporació",      required: true,  order: 1 },
      responsable_acollida:{ type: 'string', label: "Responsable d'acollida",   required: true,  order: 2 },
    },
    signingRolesSchema: {},
    sampleValues: { nom_treballador: 'Montserrat Puig Ferrer', data_incorporacio: '2025-09-01', responsable_acollida: 'Alice (Acme)' },
    children: () => [
      H1("Benvingut/da a l'empresa!"),
      BR(),
      P(T("Estimat/da "), V("nom_treballador"), T(",")),
      BR(),
      P(T("Ens complau donar-te la benvinguda a Acme Corp S.A. amb motiu de la teva incorporació el "), V("data_incorporacio"), T(".")),
      BR(),
      H2("Informació d'incorporació"),
      infoTable([
        ["Responsable d'acollida",  "responsable_acollida"],
        ["Data d'incorporació",     "data_incorporacio"],
      ]),
      BR(),
      H2("Primer dia — tasques principals"),
      P(T("  • Presentació a l'equip i visita a les instal·lacions.")),
      P(T("  • Lliurament de credencials, equipament i EPI si s'escau.")),
      P(T("  • Revisió del manual d'empleat/da i dels procediments interns.")),
      P(T("  • Alta als sistemes informàtics i eines de treball.")),
      BR(),
      H2("Recursos Humans"),
      P(T("Per a qualsevol dubte, contacta amb RRHH a rrhh@acme-corp.com o parla amb el/la teu/teva responsable d'acollida.")),
      BR(),
      P(T("T'ho desitgem de cor, molta sort en la nova etapa!")),
    ],
  },

  // ── 08 Annexe Revisió Salarial Anual ──────────────────────────────────────
  {
    id:      '72000000-0000-0000-0000-000000000008',
    localeId:'73000000-0000-0000-0000-000000000008',
    name:         'Annexe revisió salarial anual',
    description:  'Comunicació formal de revisió de salari.',
    category:     'hr',
    tenantId:     TENANT_ACME,
    isPlatformDefault: false,
    createdBy:    CREATOR_ACME,
    storagePath:  `${TENANT_ACME}/docx/08-revisio-salarial-ca.docx`,
    variablesSchema: {
      full_name:     { type: 'string', label: "Nom del treballador/a",   required: true,  role: 'worker', order: 0 },
      salari_actual: { type: 'number', label: 'Salari actual (EUR/any)', required: true,                       order: 1 },
      nou_salari:    { type: 'number', label: 'Nou salari (EUR/any)',    required: true,                       order: 2 },
      percentatge:   { type: 'number', label: 'Increment (%)',           required: true,                       order: 3 },
      data_efecte:   { type: 'date',   label: "Data d'efecte",           required: true,                       order: 4 },
    },
    signingRolesSchema: {
      worker: { entity_type: 'employee', label: "Treballador/a", order: 0, for_signing: true },
      manager:    { entity_type: 'employee', label: "Director/a",    order: 1, for_signing: true },
    },
    sampleValues: { full_name: 'Marta Rovira Figueras', salari_actual: '28000', nou_salari: '29400', percentatge: '5', data_efecte: '2026-01-01' },
    children: () => [
      H1("Annexe: Revisió Salarial Anual"),
      BR(),
      P(T("S'informa al/a la treballador/a "), V("full_name"), T(" que, com a resultat de la revisió salarial anual, la seva retribució queda establerta de la manera següent:")),
      BR(),
      infoTable([
        ["Salari brut anual actual (EUR)", "salari_actual"],
        ["Nou salari brut anual (EUR)",    "nou_salari"],
        ["Increment aplicat (%)",          "percentatge"],
        ["Data d'efecte",                  "data_efecte"],
      ]),
      BR(),
      P(T("La present comunicació constitueix un annex al contracte de treball vigent i modifica la retribució pactada inicialment, sense alterar la resta de les condicions laborals.")),
      ...SIGN_SECTION(),
    ],
  },

  // ── 09 Cessió Temporal d'Equipament ───────────────────────────────────────
  {
    id:      '72000000-0000-0000-0000-000000000009',
    localeId:'73000000-0000-0000-0000-000000000009',
    name:         "Cessió temporal d'equipament",
    description:  "Acta de cessió d'eines o dispositius.",
    category:     'operations',
    tenantId:     TENANT_ACME,
    isPlatformDefault: false,
    createdBy:    CREATOR_ACME,
    storagePath:  `${TENANT_ACME}/docx/09-cessio-equipament-ca.docx`,
    variablesSchema: {
      full_name:            { type: 'string', label: "Nom del treballador/a",  required: true,  role: 'worker', order: 0 },
      nom_equip:            { type: 'string', label: "Nom de l'equip",         required: true,                       order: 1 },
      num_serie:            { type: 'string', label: 'Número de sèrie',        required: false,                       order: 2 },
      data_cessio:          { type: 'date',   label: 'Data de cessió',         required: true,                       order: 3 },
      data_retorn_prevista: { type: 'date',   label: 'Data retorn prevista',   required: true,                       order: 4 },
    },
    signingRolesSchema: {
      worker:          { entity_type: 'employee', label: "Treballador/a",         order: 0, for_signing: true },
      warehouse_manager: { entity_type: 'employee', label: 'Responsable magatzem',  order: 1, for_signing: true },
    },
    sampleValues: { full_name: 'Sergi Costa Ribas', nom_equip: 'Tauleta de camp ruggeditzada', num_serie: 'SN-2024-0042', data_cessio: '2025-07-01', data_retorn_prevista: '2025-12-31' },
    children: () => [
      H1("Acta de Cessió Temporal d'Equipament"),
      BR(),
      P(T("Es fa constar la cessió temporal del material següent al/a la treballador/a indicat/ada:")),
      BR(),
      infoTable([
        ["Treballador/a responsable",  "full_name"],
        ["Equip cedit",                "nom_equip"],
        ["Número de sèrie",            "num_serie"],
        ["Data de cessió",             "data_cessio"],
        ["Data retorn prevista",       "data_retorn_prevista"],
      ]),
      BR(),
      P(T("El/la treballador/a declara haver rebut l'equipament en bon estat i es compromet a:")),
      P(T("  • Usar-lo exclusivament per a les tasques encomanades per l'empresa.")),
      P(T("  • Comunicar qualsevol dany, pèrdua o mal funcionament de manera immediata.")),
      P(T("  • Retornar-lo en la data prevista o a requeriment de l'empresa.")),
      ...SIGN_SECTION(),
    ],
  },

  // ── 10 Autorització d'Accés a Instal·lació ────────────────────────────────
  {
    id:      '72000000-0000-0000-0000-000000000010',
    localeId:'73000000-0000-0000-0000-000000000010',
    name:         "Autorització accés a instal·lació",
    description:  "Autorització per treballar a instal·lacions de client.",
    category:     'operations',
    tenantId:     TENANT_ACME,
    isPlatformDefault: false,
    createdBy:    CREATOR_ACME,
    storagePath:  `${TENANT_ACME}/docx/10-autoritzacio-acces-ca.docx`,
    variablesSchema: {
      full_name:     { type: 'string', label: "Nom del treballador/a", required: true,  role: 'worker', order: 0 },
      nom_client:    { type: 'string', label: 'Nom del client',        required: true,                       order: 1 },
      adreca_client: { type: 'string', label: "Adreça del client",     required: true,                       order: 2 },
      data_acces:    { type: 'date',   label: "Data d'accés",          required: true,                       order: 3 },
    },
    signingRolesSchema: {
      worker: { entity_type: 'employee', label: "Treballador/a", order: 0, for_signing: true },
      site_manager: { entity_type: 'user',     label: "Cap d'obra",    order: 1, for_signing: true },
    },
    sampleValues: { full_name: 'Jordi Soler Mas', nom_client: 'Constructora Meridian S.L.', adreca_client: "Carrer de la Indústria 45, Barcelona", data_acces: '2025-07-10' },
    children: () => [
      H1("Autorització d'Accés a Instal·lació de Client"),
      BR(),
      P(T("Per la present, Acme Corp S.A. autoritza el/la treballador/a que s'indica a accedir a les instal·lacions del client:")),
      BR(),
      infoTable([
        ["Treballador/a autoritzat/ada",  "full_name"],
        ["Client",                        "nom_client"],
        ["Adreça de les instal·lacions",  "adreca_client"],
        ["Data d'accés",                  "data_acces"],
      ]),
      BR(),
      P(T("Condicions d'accés:")),
      P(T("  • L'accés es limita exclusivament a les activitats del servei contractat.")),
      P(T("  • El/la treballador/a ha de complir les normes de seguretat internes de les instal·lacions.")),
      P(T("  • Qualsevol incidència s'ha de comunicar immediatament al cap d'obra o responsable designat.")),
      ...SIGN_SECTION(),
    ],
  },

  // ── 11 Informe d'Incident Tècnic ──────────────────────────────────────────
  {
    id:      '72000000-0000-0000-0000-000000000011',
    localeId:'73000000-0000-0000-0000-000000000011',
    name:         "Informe d'incident tècnic",
    description:  "Registre intern d'incidents (generar i arxivar).",
    category:     'safety',
    tenantId:     TENANT_ACME,
    isPlatformDefault: false,
    createdBy:    CREATOR_ACME,
    storagePath:  `${TENANT_ACME}/docx/11-informe-incident-tecnic-ca.docx`,
    variablesSchema: {
      data_incident:       { type: 'date',   label: "Data de l'incident",       required: true,  order: 0 },
      lloc:                { type: 'string', label: "Lloc de l'incident",       required: true,  order: 1 },
      descripcio_incident: { type: 'string', label: "Descripció de l'incident", required: true,  order: 2 },
      mesures_adoptades:   { type: 'string', label: 'Mesures adoptades',        required: true,  order: 3 },
    },
    signingRolesSchema: {},
    sampleValues: { data_incident: '2025-06-20', lloc: 'Sala quadres elèctrics, planta 2', descripcio_incident: 'Curtcircuit menor. Sense ferits.', mesures_adoptades: 'Substitució fusibles. Notificació al responsable.' },
    children: () => [
      H1("Informe d'Incident Tècnic"),
      BR(),
      P(T("Registre intern d'incident. Emplenar tots els camps i arxivar al sistema de gestió de PRL.")),
      BR(),
      new Table({
        width: { size: 9000, type: WidthType.DXA },
        rows: [
          reportHeaderRow("Camp", "Detall"),
          dataRow("Data de l'incident",        "data_incident"),
          dataRow("Lloc de l'incident",        "lloc"),
          dataRow("Descripció de l'incident",  "descripcio_incident"),
          dataRow("Mesures adoptades",         "mesures_adoptades"),
        ],
      }),
      BR(),
      P(T("Emplenat per: ______________________________     Data: ___________________")),
    ],
  },

  // ── 12 Acta de Traspàs de Funcions ────────────────────────────────────────
  {
    id:      '72000000-0000-0000-0000-000000000012',
    localeId:'73000000-0000-0000-0000-000000000012',
    name:         'Acta de traspàs de funcions',
    description:  'Formalitza el traspàs de funcions entre dos treballadors.',
    category:     'hr',
    tenantId:     TENANT_ACME,
    isPlatformDefault: false,
    createdBy:    CREATOR_ACME,
    storagePath:  `${TENANT_ACME}/docx/12-traspas-funcions-ca.docx`,
    variablesSchema: {
      nom_cedent:   { type: 'string', label: 'Nom del cedent',    required: true,  role: 'transferor', order: 0 },
      nom_receptor: { type: 'string', label: 'Nom del receptor',  required: true,  role: 'recipient',  order: 1 },
      funcions_traspassades: { type: 'string', label: 'Funcions traspassades',    required: true,                    order: 2 },
      data_traspas:          { type: 'date',   label: 'Data de traspàs',          required: true,                    order: 3 },
    },
    signingRolesSchema: {
      transferor:      { entity_type: 'employee', label: 'Cedent',           order: 0, for_signing: true },
      recipient:    { entity_type: 'employee', label: 'Receptor',         order: 1, for_signing: true },
      manager: { entity_type: 'employee', label: 'Responsable RRHH', order: 2, for_signing: true },
    },
    sampleValues: { nom_cedent: 'Susanna Ribas Carreras', nom_receptor: 'Júlia Montalba Safont', funcions_traspassades: 'Coordinació equip Gràcia, gestió comandes i control magatzem', data_traspas: '2025-09-15' },
    children: () => [
      H1("Acta de Traspàs de Funcions"),
      BR(),
      P(T("Mitjançant la present acta, es formalitza el traspàs de funcions entre:")),
      BR(),
      infoTable([
        ["Cedent (qui traspassa)",            "nom_cedent"],
        ["Receptor (qui rep les funcions)",   "nom_receptor"],
        ["Funcions traspassades",             "funcions_traspassades"],
        ["Data d'efecte del traspàs",         "data_traspas"],
      ]),
      BR(),
      P(T("Ambdues parts confirmen que el traspàs s'ha efectuat de manera completa i satisfactòria, havent el/la receptor/a rebut tota la informació, documentació i recursos necessaris per assumir les funcions indicades.")),
      ...SIGN_SECTION(),
    ],
  },

  // ── 13 Nota Informativa RGPD (schema-based, full_name amb role) ────────────
  {
    id:      '72000000-0000-0000-0000-000000000013',
    localeId:'73000000-0000-0000-0000-000000000013',
    name:         'Nota informativa RGPD',
    description:  'Informació al treballador sobre tractament de dades.',
    category:     'legal',
    tenantId:     TENANT_ACME,
    isPlatformDefault: false,
    createdBy:    CREATOR_ACME,
    storagePath:  `${TENANT_ACME}/docx/13-nota-rgpd-ca.docx`,
    variablesSchema: {
      full_name: { type: 'string', label: "Nom del treballador/a", required: true,  role: 'worker', order: 0 },
      data:      { type: 'date',   label: 'Data',                  required: true,                       order: 1 },
    },
    signingRolesSchema: {
      worker: { entity_type: 'employee', label: "Treballador/a (confirmació recepció)", order: 0, for_signing: true },
    },
    sampleValues: { full_name: 'Marta Rovira Figueras', data: '2025-07-01' },
    children: () => [
      H1("Nota Informativa sobre Protecció de Dades (RGPD)"),
      BR(),
      H2("Responsable del tractament"),
      P(T("Acme Corp S.A., CIF B-12345678, amb domicili social a Carrer Major 1, Barcelona.")),
      BR(),
      H2("Finalitat del tractament"),
      P(T("Les seves dades personals seran tractades per gestionar la relació laboral, complir les obligacions legals derivades d'aquesta, i administrar la nòmina i els beneficis socials.")),
      BR(),
      H2("Base legal"),
      P(T("Execució del contracte de treball (art. 6.1.b RGPD) i compliment d'obligacions legals (art. 6.1.c RGPD).")),
      BR(),
      H2("Drets"),
      P(T("Pot exercir els drets d'accés, rectificació, supressió, portabilitat, limitació i oposició enviant una sol·licitud a rrhh@acme-corp.com, adjuntant còpia del document d'identitat.")),
      BR(),
      P(T("Confirmo, "), V("full_name"), T(", haver rebut i llegit la present informació sobre protecció de dades.")),
      P(T("Data: "), V("data")),
      ...SIGN_SECTION(),
    ],
  },

  // ── 14 Informe de Seguiment Setmanal ──────────────────────────────────────
  {
    id:      '72000000-0000-0000-0000-000000000014',
    localeId:'73000000-0000-0000-0000-000000000014',
    name:         'Informe de seguiment setmanal',
    description:  "Resum d'activitats setmanals per a direcció.",
    category:     'operations',
    tenantId:     TENANT_ACME,
    isPlatformDefault: false,
    createdBy:    CREATOR_ACME,
    storagePath:  `${TENANT_ACME}/docx/14-informe-seguiment-setmanal-ca.docx`,
    variablesSchema: {
      setmana:      { type: 'string', label: 'Setmana (ex: 2025-W28)',     required: true,  order: 0 },
      responsable:  { type: 'string', label: 'Responsable',                required: true,  order: 1 },
      activitats:   { type: 'string', label: 'Activitats realitzades',     required: true,  order: 2 },
      observacions: { type: 'string', label: 'Observacions',               required: false, order: 3 },
    },
    signingRolesSchema: {},
    sampleValues: { setmana: '2025-W28', responsable: 'Marta Rovira Figueras', activitats: 'Revisió quadres elèctrics edifici A i B. Manteniment preventiu de equips.', observacions: 'Pendent reposició peces quadre B.' },
    children: () => [
      H1("Informe de Seguiment Setmanal"),
      BR(),
      new Table({
        width: { size: 9000, type: WidthType.DXA },
        rows: [
          reportHeaderRow("Camp", "Detall"),
          dataRow("Setmana",                "setmana"),
          dataRow("Responsable",            "responsable"),
          dataRow("Activitats realitzades", "activitats"),
          dataRow("Observacions",           "observacions"),
        ],
      }),
      BR(),
      P(T("Emplenat per: ______________________________     Data de lliurament: ___________________")),
    ],
  },

  // ── 15 Test de Firmes (etiquetes DocuSeal per a proves de signatura) ───────
  {
    id:      '72000000-0000-0000-0000-000000000015',
    localeId:'73000000-0000-0000-0000-000000000015',
    name:         'Test de firmes',
    description:  'Document de referència per a proves de signatura (DocuSeal i firma pròpia).',
    category:     'signing',
    tenantId:     null,
    isPlatformDefault: true,
    createdBy:    CREATOR_PLATFORM,
    storagePath:  'platform/docx/15-test-de-firmes-ca.docx',
    variablesSchema: {
      'worker.full_name': { type: 'string', label: 'Nom treballador/a', required: true, role: 'worker', order: 0 },
      data_prova:         { type: 'date',   label: 'Data de la prova',  required: true,                    order: 1 },
      notes:              { type: 'string', label: 'Notes de prova',    required: false,                   order: 2 },
    },
    signingRolesSchema: {
      worker:  { entity_type: 'employee', label: 'Treballador/a', order: 0, for_signing: true },
      manager: { entity_type: 'employee', label: 'Responsable',   order: 1, for_signing: true },
    },
    sampleValues: {
      'worker.full_name': 'Marc Vila Bosch',
      data_prova:         '2026-06-15',
      notes:              'Plantilla de prova per a DocuSeal i firma pròpia',
    },
    children: () => [
      H1('Test de Firmes'),
      BR(),
      P(T('Document de prova generat el '), V('data_prova'), T('.')),
      P(T('Treballador/a: '), V('worker.full_name')),
      P(T('Notes: '), V('notes')),
      BR(),
      P(B('Signatura treballador/a:')),
      P(F('FirmaTreballador', 'signature', 'worker')),
      BR(),
      P(B('Data signatura treballador/a:')),
      P(F('DataTreballador', 'date', 'worker')),
      BR(),
      P(B('Signatura responsable:')),
      P(F('FirmaResponsable', 'signature', 'manager')),
    ],
  },

  // ── 16 Carta d'advertència laboral ─────────────────────────────────────────
  {
    id: '72000000-0000-0000-0000-000000000016',
    localeId: '73000000-0000-0000-0000-000000000016',
    name: "Carta d'advertència laboral",
    description: "Comunicació formal d'advertència o amonestació a l'empleat/da.",
    category: 'hr',
    tenantId: null,
    isPlatformDefault: true,
    createdBy: CREATOR_PLATFORM,
    storagePath: 'platform/docx/16-carta-advertencia-ca.docx',
    targetArchetypes: ['generic', 'practice', 'hospitality', 'workshop_maker'],
    variablesSchema: {
      data_avis: { type: 'date', label: "Data de l'advertència", required: true, order: 0 },
      descripcio_incidencia: { type: 'string', label: 'Descripció incidència', required: true, order: 1 },
      motiu: { type: 'string', label: 'Motiu', required: true, order: 2 },
      gravetat: { type: 'string', label: 'Gravetat', required: false, order: 3 },
    },
    signingRolesSchema: {
      worker: { entity_type: 'employee', label: 'Treballador/a', order: 0, for_signing: true },
      hr_manager: { entity_type: 'employee', label: 'Responsable RRHH', order: 1, for_signing: true },
    },
    sampleValues: { data_avis: '2026-03-01', descripcio_incidencia: 'Retards reiterats', motiu: 'Incompliment horari', gravetat: 'lleu' },
    children: () => [
      H1("Carta d'Advertència"),
      P(T("A l'atenció de "), V('worker.full_name'), T(' (DNI '), V('worker.document_id'), T(').')),
      P(T('Incidència: '), V('descripcio_incidencia'), T('. Motiu: '), V('motiu')),
      P(F('FirmaTreballador', 'signature', 'worker')),
      P(F('FirmaRRHH', 'signature', 'hr_manager')),
    ],
  },

  // ── 17 Acord de teletreball ────────────────────────────────────────────────
  {
    id: '72000000-0000-0000-0000-000000000017',
    localeId: '73000000-0000-0000-0000-000000000017',
    name: 'Acord de teletreball',
    description: 'Acord individual de treball a distància.',
    category: 'hr',
    tenantId: null,
    isPlatformDefault: true,
    createdBy: CREATOR_PLATFORM,
    storagePath: 'platform/docx/17-acord-teletreball-ca.docx',
    targetArchetypes: ['generic', 'practice'],
    variablesSchema: {
      data_inici: { type: 'date', label: "Data d'inici", required: true, order: 0 },
      dies_tele: { type: 'string', label: 'Dies de teletreball', required: true, order: 1 },
      horari: { type: 'string', label: 'Horari', required: true, order: 2 },
      lloc_treball: { type: 'string', label: 'Lloc de treball', required: true, order: 3 },
    },
    signingRolesSchema: {
      worker: { entity_type: 'employee', label: 'Treballador/a', order: 0, for_signing: true },
      hr_manager: { entity_type: 'employee', label: 'Responsable RRHH', order: 1, for_signing: true },
    },
    sampleValues: { data_inici: '2026-04-01', dies_tele: 'Dl-Dv', horari: '9-18h', lloc_treball: 'Domicili' },
    children: () => [
      H1('Acord de Teletreball'),
      P(T('Treballador/a: '), V('worker.full_name')),
      infoTable([['Data inici', 'data_inici'], ['Dies', 'dies_tele'], ['Horari', 'horari'], ['Lloc', 'lloc_treball']]),
      ...SIGN_SECTION(),
    ],
  },

  // ── 18 Consentiment informat ───────────────────────────────────────────────
  {
    id: '72000000-0000-0000-0000-000000000018',
    localeId: '73000000-0000-0000-0000-000000000018',
    name: 'Consentiment informat',
    description: 'Full de consentiment informat per a actes o tractaments.',
    category: 'legal',
    tenantId: null,
    isPlatformDefault: true,
    createdBy: CREATOR_PLATFORM,
    storagePath: 'platform/docx/18-consentiment-informat-ca.docx',
    targetArchetypes: ['practice'],
    variablesSchema: {
      procediment: { type: 'string', label: 'Procediment', required: true, order: 0 },
      data_consentiment: { type: 'date', label: 'Data', required: true, order: 1 },
    },
    signingRolesSchema: {
      client_signatory: { entity_type: 'contact', label: 'Pacient/Client', order: 0, for_signing: true },
    },
    sampleValues: { procediment: 'Tractament dental rutinari', data_consentiment: '2026-03-10' },
    children: () => [
      H1('Consentiment informat'),
      P(T('Pacient/Client: '), V('client_signatory.display_name')),
      P(T('Procediment: '), V('procediment')),
      P(F('FirmaClient', 'signature', 'client_signatory')),
    ],
  },

  // ── 19 Full d'admissió ─────────────────────────────────────────────────────
  {
    id: '72000000-0000-0000-0000-000000000019',
    localeId: '73000000-0000-0000-0000-000000000019',
    name: "Full d'admissió de pacient/client",
    description: "Obertura d'expedient amb dades del pacient o client.",
    category: 'operations',
    tenantId: null,
    isPlatformDefault: true,
    createdBy: CREATOR_PLATFORM,
    storagePath: 'platform/docx/19-full-admissio-ca.docx',
    targetArchetypes: ['practice'],
    variablesSchema: {
      motiu: { type: 'string', label: 'Motiu consulta', required: true, order: 0 },
      antecedents: { type: 'string', label: 'Antecedents', required: false, order: 1 },
      data_admissio: { type: 'date', label: 'Data admissió', required: true, order: 2 },
    },
    signingRolesSchema: {
      client_signatory: { entity_type: 'contact', label: 'Pacient/Client', order: 0, for_signing: true },
    },
    sampleValues: { motiu: 'Primera visita', antecedents: '', data_admissio: '2026-03-10' },
    children: () => [
      H1("Full d'admissió"),
      P(T('Client: '), V('client_signatory.display_name')),
      infoTable([['Motiu', 'motiu'], ['Antecedents', 'antecedents'], ['Data', 'data_admissio']]),
      P(F('FirmaClient', 'signature', 'client_signatory')),
    ],
  },

  // ── 20 Informe de visita ───────────────────────────────────────────────────
  {
    id: '72000000-0000-0000-0000-000000000020',
    localeId: '73000000-0000-0000-0000-000000000020',
    name: 'Informe de visita o sessió',
    description: 'Registre intern de visita professional (sense signatura).',
    category: 'operations',
    tenantId: null,
    isPlatformDefault: true,
    createdBy: CREATOR_PLATFORM,
    storagePath: 'platform/docx/20-informe-visita-ca.docx',
    targetArchetypes: ['practice'],
    variablesSchema: {
      data_visita: { type: 'date', label: 'Data visita', required: true, order: 0 },
      observacions: { type: 'string', label: 'Observacions', required: true, order: 1 },
      pla_seguiment: { type: 'string', label: 'Pla de seguiment', required: false, order: 2 },
    },
    signingRolesSchema: {},
    sampleValues: { data_visita: '2026-03-10', observacions: 'Evolució favorable', pla_seguiment: 'Revisió en 30 dies' },
    children: () => [
      H1('Informe de visita'),
      P(T('Professional: '), V('worker.full_name'), T(' · Client: '), V('client_signatory.display_name')),
      infoTable([['Data', 'data_visita'], ['Observacions', 'observacions'], ['Pla', 'pla_seguiment']]),
    ],
  },

  // ── 21 Intervenció tècnica ─────────────────────────────────────────────────
  {
    id: '72000000-0000-0000-0000-000000000021',
    localeId: '73000000-0000-0000-0000-000000000021',
    name: "Full d'intervenció tècnica",
    description: "Acta d'intervenció a domicili o instal·lació del client.",
    category: 'operations',
    tenantId: null,
    isPlatformDefault: true,
    createdBy: CREATOR_PLATFORM,
    storagePath: 'platform/docx/21-intervencio-tecnica-ca.docx',
    targetArchetypes: ['field_service'],
    variablesSchema: {
      data_intervencio: { type: 'date', label: 'Data', required: true, order: 0 },
      adreca: { type: 'string', label: 'Adreça', required: true, order: 1 },
      descripcio_treballs: { type: 'string', label: 'Treballs', required: true, order: 2 },
      materials: { type: 'string', label: 'Materials', required: false, order: 3 },
    },
    signingRolesSchema: {
      technician: { entity_type: 'employee', label: 'Tècnic/a', order: 0, for_signing: true },
      client_signatory: { entity_type: 'contact', label: 'Client', order: 1, for_signing: true },
    },
    sampleValues: { data_intervencio: '2026-03-10', adreca: 'C/ Exemple 1', descripcio_treballs: 'Reparació instal·lació', materials: 'Canonades' },
    children: () => [
      H1("Full d'intervenció tècnica"),
      infoTable([['Tècnic', 'technician.full_name'], ['Client', 'client_signatory.display_name'], ['Data', 'data_intervencio'], ['Adreça', 'adreca'], ['Treballs', 'descripcio_treballs']]),
      P(F('FirmaTecnic', 'signature', 'technician')),
      P(F('FirmaClient', 'signature', 'client_signatory')),
    ],
  },

  // ── 22 Pressupost obra ─────────────────────────────────────────────────────
  {
    id: '72000000-0000-0000-0000-000000000022',
    localeId: '73000000-0000-0000-0000-000000000022',
    name: "Pressupost d'obra o instal·lació",
    description: 'Oferta econòmica per a client amb acceptació per signatura.',
    category: 'commercial',
    tenantId: null,
    isPlatformDefault: true,
    createdBy: CREATOR_PLATFORM,
    storagePath: 'platform/docx/22-pressupost-obra-ca.docx',
    targetArchetypes: ['field_service', 'workshop_maker'],
    variablesSchema: {
      data_pressupost: { type: 'date', label: 'Data', required: true, order: 0 },
      concepte: { type: 'string', label: 'Concepte', required: true, order: 1 },
      import_total: { type: 'number', label: 'Import (EUR)', required: true, order: 2 },
      validesa_dies: { type: 'number', label: 'Dies validesa', required: true, order: 3 },
    },
    signingRolesSchema: {
      client_signatory: { entity_type: 'contact', label: 'Client', order: 0, for_signing: true },
    },
    sampleValues: { data_pressupost: '2026-03-10', concepte: 'Instal·lació climatització', import_total: '4500', validesa_dies: '30' },
    children: () => [
      H1('Pressupost'),
      P(T('Client: '), V('client_signatory.display_name')),
      infoTable([['Concepte', 'concepte'], ['Import', 'import_total'], ['Validesa (dies)', 'validesa_dies']]),
      P(F('FirmaClient', 'signature', 'client_signatory')),
    ],
  },

  // ── 23 Certificat finalització ─────────────────────────────────────────────
  {
    id: '72000000-0000-0000-0000-000000000023',
    localeId: '73000000-0000-0000-0000-000000000023',
    name: 'Certificat de finalització de treballs',
    description: 'Certificació de treballs completats amb signatura del client.',
    category: 'operations',
    tenantId: null,
    isPlatformDefault: true,
    createdBy: CREATOR_PLATFORM,
    storagePath: 'platform/docx/23-certificat-finalitzacio-ca.docx',
    targetArchetypes: ['field_service'],
    variablesSchema: {
      descripcio: { type: 'string', label: 'Descripció', required: true, order: 0 },
      data_fi: { type: 'date', label: 'Data finalització', required: true, order: 1 },
      adreca: { type: 'string', label: 'Adreça', required: true, order: 2 },
    },
    signingRolesSchema: {
      technician: { entity_type: 'employee', label: 'Tècnic/a', order: 0, for_signing: true },
      client_signatory: { entity_type: 'contact', label: 'Client', order: 1, for_signing: true },
    },
    sampleValues: { descripcio: 'Instal·lació completa', data_fi: '2026-03-15', adreca: 'C/ Exemple 1' },
    children: () => [
      H1('Certificat de finalització'),
      P(V('descripcio')),
      infoTable([['Data fi', 'data_fi'], ['Adreça', 'adreca']]),
      P(F('FirmaTecnic', 'signature', 'technician')),
      P(F('FirmaClient', 'signature', 'client_signatory')),
    ],
  },

  // ── 24 Reserva esdeveniment ────────────────────────────────────────────────
  {
    id: '72000000-0000-0000-0000-000000000024',
    localeId: '73000000-0000-0000-0000-000000000024',
    name: "Contracte de reserva d'esdeveniment",
    description: 'Reserva de sala o esdeveniment privat amb signatura del client.',
    category: 'commercial',
    tenantId: null,
    isPlatformDefault: true,
    createdBy: CREATOR_PLATFORM,
    storagePath: 'platform/docx/24-reserva-esdeveniment-ca.docx',
    targetArchetypes: ['hospitality'],
    variablesSchema: {
      data_esdeveniment: { type: 'date', label: 'Data esdeveniment', required: true, order: 0 },
      horari: { type: 'string', label: 'Horari', required: true, order: 1 },
      num_persones: { type: 'number', label: 'Persones', required: true, order: 2 },
      import_reserva: { type: 'number', label: 'Import (EUR)', required: true, order: 3 },
    },
    signingRolesSchema: {
      client_signatory: { entity_type: 'contact', label: 'Client', order: 0, for_signing: true },
    },
    sampleValues: { data_esdeveniment: '2026-06-20', horari: '20:00-01:00', num_persones: '40', import_reserva: '3200' },
    children: () => [
      H1("Reserva d'esdeveniment"),
      infoTable([['Client', 'client_signatory.display_name'], ['Data', 'data_esdeveniment'], ['Horari', 'horari'], ['Persones', 'num_persones'], ['Import', 'import_reserva']]),
      P(F('FirmaClient', 'signature', 'client_signatory')),
    ],
  },

  // ── 25 Comanda càtering ────────────────────────────────────────────────────
  {
    id: '72000000-0000-0000-0000-000000000025',
    localeId: '73000000-0000-0000-0000-000000000025',
    name: 'Full de comanda de càtering',
    description: 'Comanda interna de càtering (sense signatura).',
    category: 'operations',
    tenantId: null,
    isPlatformDefault: true,
    createdBy: CREATOR_PLATFORM,
    storagePath: 'platform/docx/25-comanda-catering-ca.docx',
    targetArchetypes: ['hospitality'],
    variablesSchema: {
      nom_esdeveniment: { type: 'string', label: 'Esdeveniment', required: true, order: 0 },
      data_lliurament: { type: 'date', label: 'Data lliurament', required: true, order: 1 },
      detall_comanda: { type: 'string', label: 'Detall', required: true, order: 2 },
    },
    signingRolesSchema: {
      worker: { entity_type: 'employee', label: 'Responsable', order: 0, for_signing: false },
    },
    sampleValues: { nom_esdeveniment: 'Boda Garcia', data_lliurament: '2026-06-20', detall_comanda: '120 racions' },
    children: () => [
      H1('Comanda de càtering'),
      infoTable([['Esdeveniment', 'nom_esdeveniment'], ['Data', 'data_lliurament'], ['Detall', 'detall_comanda']]),
      P(T('Responsable: '), V('worker.full_name')),
    ],
  },

  // ── 26 Ordre de reparació ──────────────────────────────────────────────────
  {
    id: '72000000-0000-0000-0000-000000000026',
    localeId: '73000000-0000-0000-0000-000000000026',
    name: 'Ordre de reparació',
    description: "Recepció d'equipament o vehicle amb signatura del client.",
    category: 'operations',
    tenantId: null,
    isPlatformDefault: true,
    createdBy: CREATOR_PLATFORM,
    storagePath: 'platform/docx/26-ordre-reparacio-ca.docx',
    targetArchetypes: ['workshop_maker'],
    variablesSchema: {
      descripcio_equip: { type: 'string', label: 'Equip', required: true, order: 0 },
      avaria: { type: 'string', label: 'Avaria', required: true, order: 1 },
      data_recepcio: { type: 'date', label: 'Data recepció', required: true, order: 2 },
    },
    signingRolesSchema: {
      client_signatory: { entity_type: 'contact', label: 'Client', order: 0, for_signing: true },
    },
    sampleValues: { descripcio_equip: 'Bicicleta MTB', avaria: 'Canvi trencat', data_recepcio: '2026-03-10' },
    children: () => [
      H1('Ordre de reparació'),
      infoTable([['Client', 'client_signatory.display_name'], ['Equip', 'descripcio_equip'], ['Avaria', 'avaria'], ['Data', 'data_recepcio']]),
      P(F('FirmaClient', 'signature', 'client_signatory')),
    ],
  },

  // ── 27 Pressupost reparació ────────────────────────────────────────────────
  {
    id: '72000000-0000-0000-0000-000000000027',
    localeId: '73000000-0000-0000-0000-000000000027',
    name: 'Pressupost de reparació',
    description: 'Pressupost amb acceptació del client.',
    category: 'commercial',
    tenantId: null,
    isPlatformDefault: true,
    createdBy: CREATOR_PLATFORM,
    storagePath: 'platform/docx/27-pressupost-reparacio-ca.docx',
    targetArchetypes: ['workshop_maker'],
    variablesSchema: {
      descripcio_equip: { type: 'string', label: 'Equip', required: true, order: 0 },
      import_total: { type: 'number', label: 'Import (EUR)', required: true, order: 1 },
      validesa_dies: { type: 'number', label: 'Dies validesa', required: true, order: 2 },
    },
    signingRolesSchema: {
      client_signatory: { entity_type: 'contact', label: 'Client', order: 0, for_signing: true },
    },
    sampleValues: { descripcio_equip: 'Bicicleta MTB', import_total: '85', validesa_dies: '15' },
    children: () => [
      H1('Pressupost de reparació'),
      infoTable([['Client', 'client_signatory.display_name'], ['Equip', 'descripcio_equip'], ['Import', 'import_total']]),
      P(F('FirmaClient', 'signature', 'client_signatory')),
    ],
  },

  // ── 28 Certificat de lliurament ────────────────────────────────────────────
  {
    id: '72000000-0000-0000-0000-000000000028',
    localeId: '73000000-0000-0000-0000-000000000028',
    name: 'Certificat de lliurament',
    description: "Lliurament d'equip reparat amb signatura del client.",
    category: 'operations',
    tenantId: null,
    isPlatformDefault: true,
    createdBy: CREATOR_PLATFORM,
    storagePath: 'platform/docx/28-certificat-lliurament-ca.docx',
    targetArchetypes: ['workshop_maker'],
    variablesSchema: {
      descripcio_equip: { type: 'string', label: 'Equip', required: true, order: 0 },
      data_lliurament: { type: 'date', label: 'Data lliurament', required: true, order: 1 },
      import_cobrat: { type: 'number', label: 'Import cobrat (EUR)', required: false, order: 2 },
    },
    signingRolesSchema: {
      client_signatory: { entity_type: 'contact', label: 'Client', order: 0, for_signing: true },
    },
    sampleValues: { descripcio_equip: 'Bicicleta MTB', data_lliurament: '2026-03-12', import_cobrat: '85' },
    children: () => [
      H1('Certificat de lliurament'),
      P(T('Client: '), V('client_signatory.display_name')),
      infoTable([['Equip', 'descripcio_equip'], ['Data', 'data_lliurament'], ['Import', 'import_cobrat']]),
      P(F('FirmaClient', 'signature', 'client_signatory')),
    ],
  },
]

// ─── Generació DOCX ───────────────────────────────────────────────────────────

async function buildDocxBuffer(tpl) {
  const doc = new Document({
    creator:     'App Seed Script',
    title:       tpl.name,
    description: tpl.description,
    sections: [{
      properties: {
        page: {
          margin: { top: 1440, right: 1080, bottom: 1440, left: 1080 }, // 1" t/b, 0.75" l/r
        },
      },
      children: tpl.children(),
    }],
  })
  return Packer.toBuffer(doc)
}

// ─── Pujada a Supabase Storage ────────────────────────────────────────────────

async function uploadToStorage(storagePath, buffer) {
  const url = `${SUPABASE_URL}/storage/v1/object/${BUCKET}/${storagePath}`
  const res = await fetch(url, {
    method:  'POST',
    headers: {
      'Authorization': `Bearer ${SERVICE_ROLE_KEY}`,
      'Content-Type':  DOCX_MIME,
      'x-upsert':      'true',
    },
    body: buffer,
  })
  if (!res.ok) {
    const msg = await res.text().catch(() => '')
    throw new Error(`HTTP ${res.status}: ${msg.slice(0, 200)}`)
  }
}

// ─── Generació SQL ────────────────────────────────────────────────────────────

function sqlStr(s)  { return s === null ? 'NULL' : `'${String(s).replace(/'/g, "''")}'` }
function sqlBool(b) { return b ? 'true' : 'false' }
function sqlJson(o) { return o === null ? 'NULL' : `'${JSON.stringify(o).replace(/'/g, "''")}'` }

function generateSQL(templates) {
  const hasArchetypes = templates.some((t) => t.targetArchetypes?.length)
  const tplCols = hasArchetypes
    ? '  (id, tenant_id, name, description, category, template_type, is_platform_default, is_active, created_by, target_archetypes)'
    : '  (id, tenant_id, name, description, category, template_type, is_platform_default, is_active, created_by)'

  const lines = [
    '',
    '-- ─── Plantilles de documents DOCX ─────────────────────────────────────────',
    '-- Prefix 72: document_templates  (001-028, template_type=\'docx\')',
    '-- Prefix 73: document_template_locales (001-028, locale=\'ca\', mime=docx)',
    '-- Generat amb: cd scripts && node generate-docx-seed.mjs',
    '',
    'INSERT INTO data.document_templates',
    tplCols,
    'VALUES',
  ]

  const tplRows = templates.map((t) => {
    const base = `  (${sqlStr(t.id)}, ${sqlStr(t.tenantId)}, ${sqlStr(t.name)}, ${sqlStr(t.description)}, ${sqlStr(t.category)}, 'docx', ${sqlBool(t.isPlatformDefault)}, true, ${sqlStr(t.createdBy)}`
    if (hasArchetypes && t.targetArchetypes?.length) {
      return `${base}, ARRAY[${t.targetArchetypes.map((a) => `'${a}'`).join(',')}])`
    }
    return `${base})`
  })
  lines.push(tplRows.join(',\n'))
  lines.push('ON CONFLICT DO NOTHING;')
  lines.push('')
  lines.push('INSERT INTO data.document_template_locales')
  lines.push(`  (id, template_id, locale, mime_type, storage_path, html_content, variables_schema, signing_roles_schema, sample_values, is_active)`)
  lines.push('VALUES')

  const locRows = templates.map(t =>
    [
      '(',
      `  ${sqlStr(t.localeId)}, ${sqlStr(t.id)}, 'ca',`,
      `  '${DOCX_MIME}',`,
      `  ${sqlStr(t.storagePath)}, NULL,`,
      `  ${sqlJson(t.variablesSchema)},`,
      `  ${sqlJson(t.signingRolesSchema)},`,
      `  ${sqlJson(t.sampleValues)},`,
      `  true`,
      ')',
    ].join('\n')
  )
  lines.push(locRows.join(',\n'))
  lines.push('ON CONFLICT DO NOTHING;')

  return lines.join('\n')
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  console.log('\n🔷  Generant plantilles DOCX de seed...\n')

  // Directori de sortida local
  const outDir  = path.join(__dirname, '..', 'tmp', 'docx-seed')
  const sqlFile = path.join(__dirname, '..', 'tmp', 'seed-docx-templates.sql')
  if (!existsSync(outDir)) await mkdir(outDir, { recursive: true })

  const doUpload = Boolean(SERVICE_ROLE_KEY)
  if (!doUpload) {
    console.log('⚠  No hi ha un JWT service_role (eyJ…). El JWT secret hex no serveix per a Storage.')
    console.log('    Usa `supabase status` i exporta SUPABASE_SERVICE_ROLE_KEY, o deixa que el script el llegeixi del CLI.')
    console.log('   Per obtenir la clau:  supabase status\n')
  }

  let ok = 0
  let uploadOk = 0

  for (const tpl of TEMPLATES) {
    const fileName = path.basename(tpl.storagePath)
    let buffer
    try {
      buffer = await buildDocxBuffer(tpl)
      const localPath = path.join(outDir, fileName)
      await writeFile(localPath, buffer)
      console.log(`  ✓  ${fileName}  (${(buffer.length / 1024).toFixed(1)} KB)`)
      ok++
    } catch (err) {
      console.error(`  ✗  ${fileName}: error en generar — ${err.message}`)
      continue
    }

    if (doUpload) {
      try {
        await uploadToStorage(tpl.storagePath, buffer)
        console.log(`       ↑ pujat → ${tpl.storagePath}`)
        uploadOk++
      } catch (err) {
        console.error(`       ✗ error pujant ${tpl.storagePath}: ${err.message}`)
      }
    }
  }

  // Escriu SQL (totes les plantilles; per migració només cal 016-028)
  const sql = generateSQL(TEMPLATES)
  const sqlNew = generateSQL(TEMPLATES.filter((t) => t.id >= '72000000-0000-0000-0000-000000000016'))
  await writeFile(sqlFile, sql, 'utf8')
  await writeFile(path.join(__dirname, '..', 'tmp', 'seed-docx-templates-016-028.sql'), sqlNew, 'utf8')

  const { runCommercialDocxSeed } = await import('./generate-commercial-docx-seed.mjs')
  await runCommercialDocxSeed()

  // Resum final
  console.log(`\n─────────────────────────────────────────────────────────────────────────────`)
  console.log(`  DOCX generats:  ${ok} / ${TEMPLATES.length}  →  tmp/docx-seed/`)
  if (doUpload) {
    console.log(`  Pujats Storage: ${uploadOk} / ${ok}  →  bucket "${BUCKET}"`)
  }
  console.log(`  SQL generat:    tmp/seed-docx-templates.sql`)
  console.log(`─────────────────────────────────────────────────────────────────────────────`)
  console.log()
  console.log('  Comercials:       generate-commercial-docx-seed.mjs (cridat aquí; veure scripts/README.md)')
  console.log()
}

main().catch((err) => {
  console.error('\n✗  Error fatal:', err.message)
  process.exit(1)
})
