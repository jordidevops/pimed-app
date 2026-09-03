// ─── Catàleg de rols suggerits v1 ──────────────────────────────────────────────
// Constant client-side. No requereix DB.
// Consumida per TemplateFormModal (pills + datalist) i per PR5 (settings).

export type RoleEntityType = 'employee' | 'contact' | 'user' | 'person' | 'site' | 'asset' | 'tenant' | 'catalog_item'
export type RoleCategory = 'core' | 'hr' | 'ops' | 'commercial'

export interface CatalogRole {
  key:         string
  entity_type: RoleEntityType
  for_signing: boolean
  labels:      { ca: string; es: string; en: string }
  category:    RoleCategory
}

export const ROLE_CATALOG: CatalogRole[] = [
  // ── Core transversal ──────────────────────────────────────────────────────
  { key: 'worker',               entity_type: 'employee',      for_signing: true,  category: 'core',       labels: { ca: 'Empleat/da',           es: 'Empleado/a',              en: 'Worker'                } },
  { key: 'manager',              entity_type: 'employee',      for_signing: true,  category: 'core',       labels: { ca: 'Responsable',          es: 'Responsable',             en: 'Manager'               } },
  { key: 'approver',             entity_type: 'employee',      for_signing: true,  category: 'core',       labels: { ca: 'Aprovador/a',          es: 'Aprobador/a',             en: 'Approver'              } },
  { key: 'reviewer',             entity_type: 'employee',      for_signing: true,  category: 'core',       labels: { ca: 'Revisor/a',            es: 'Revisor/a',               en: 'Reviewer'              } },
  { key: 'requester',            entity_type: 'employee',      for_signing: false, category: 'core',       labels: { ca: 'Sol·licitant',         es: 'Solicitante',             en: 'Requester'             } },
  { key: 'transferor',           entity_type: 'employee',      for_signing: true,  category: 'core',       labels: { ca: 'Cedent',               es: 'Cedente',                 en: 'Transferor'            } },
  { key: 'recipient',            entity_type: 'employee',      for_signing: true,  category: 'core',       labels: { ca: 'Receptor/a',           es: 'Receptor/a',              en: 'Recipient'             } },
  { key: 'external_party',       entity_type: 'contact',       for_signing: true,  category: 'core',       labels: { ca: 'Part externa',         es: 'Parte externa',           en: 'External party'        } },
  { key: 'legal_representative', entity_type: 'user',          for_signing: true,  category: 'core',       labels: { ca: 'Representant legal',   es: 'Representante legal',     en: 'Legal representative'  } },

  // ── RRHH ─────────────────────────────────────────────────────────────────
  { key: 'hr_manager',           entity_type: 'employee',      for_signing: true,  category: 'hr',         labels: { ca: 'Responsable RRHH',     es: 'Responsable RRHH',        en: 'HR Manager'            } },
  { key: 'direct_manager',       entity_type: 'employee',      for_signing: true,  category: 'hr',         labels: { ca: 'Cap immediat',         es: 'Responsable directo/a',   en: 'Direct Manager'        } },
  { key: 'hr_director',          entity_type: 'employee',      for_signing: true,  category: 'hr',         labels: { ca: 'Director/a RRHH',      es: 'Director/a RRHH',         en: 'HR Director'           } },
  { key: 'payroll_responsible',  entity_type: 'user',          for_signing: false, category: 'hr',         labels: { ca: 'Responsable nòmina',   es: 'Responsable nómina',      en: 'Payroll Responsible'   } },

  // ── Operacions / EAM / CAFM ───────────────────────────────────────────────
  { key: 'technician',           entity_type: 'employee',      for_signing: true,  category: 'ops',        labels: { ca: 'Tècnic/a',             es: 'Técnico/a',               en: 'Technician'            } },
  { key: 'safety_supervisor',    entity_type: 'employee',      for_signing: true,  category: 'ops',        labels: { ca: 'Supervisor/a PRL',     es: 'Supervisor/a PRL',        en: 'Safety Supervisor'     } },
  { key: 'site_manager',         entity_type: 'user',          for_signing: true,  category: 'ops',        labels: { ca: "Cap d'instal·lació",  es: 'Jefe/a de instalación',   en: 'Site Manager'          } },
  { key: 'warehouse_manager',    entity_type: 'employee',      for_signing: true,  category: 'ops',        labels: { ca: 'Cap de magatzem',       es: 'Jefe/a de almacén',       en: 'Warehouse Manager'     } },
  { key: 'asset_custodian',      entity_type: 'employee',      for_signing: false, category: 'ops',        labels: { ca: "Custodi d'actiu",      es: 'Custodio de activo',      en: 'Asset Custodian'       } },
  { key: 'service_item',         entity_type: 'catalog_item',  for_signing: false, category: 'ops',        labels: { ca: 'Servei contractat',     es: 'Servicio contratado',     en: 'Service item'          } },
  { key: 'product_item',         entity_type: 'catalog_item',  for_signing: false, category: 'ops',        labels: { ca: 'Producte referit',      es: 'Producto referido',       en: 'Product item'          } },

  // ── Comercial / Legal ─────────────────────────────────────────────────────
  { key: 'client_signatory',     entity_type: 'contact',       for_signing: true,  category: 'commercial', labels: { ca: 'Signant client',        es: 'Firmante cliente',        en: 'Client Signatory'      } },
  { key: 'supplier_signatory',   entity_type: 'contact',       for_signing: true,  category: 'commercial', labels: { ca: 'Signant proveïdor',     es: 'Firmante proveedor',      en: 'Supplier Signatory'    } },
  { key: 'customer',             entity_type: 'contact',       for_signing: true,  category: 'commercial', labels: { ca: 'Client',                es: 'Cliente',                 en: 'Customer'              } },
  { key: 'vendor',               entity_type: 'contact',       for_signing: true,  category: 'commercial', labels: { ca: 'Proveïdor',             es: 'Proveedor',               en: 'Vendor'                } },
  { key: 'contractor',           entity_type: 'contact',       for_signing: true,  category: 'commercial', labels: { ca: 'Contractista',          es: 'Contratista',             en: 'Contractor'            } },
  { key: 'partner',              entity_type: 'contact',       for_signing: true,  category: 'commercial', labels: { ca: 'Soci/Sòcia',            es: 'Socio/Socia',             en: 'Partner'               } },
  { key: 'compliance_officer',   entity_type: 'user',          for_signing: false, category: 'commercial', labels: { ca: 'Responsable compliment', es: 'Responsable cumplimiento', en: 'Compliance Officer'   } },
]

/** Mapa ràpid: key → CatalogRole */
export const ROLE_CATALOG_BY_KEY = Object.fromEntries(ROLE_CATALOG.map(r => [r.key, r]))

/** Rols que solen resoldre's automàticament des del context del document (generació/orquestrador). */
export const CONTEXT_AUTO_ROLE_KEYS = new Set([
  'worker',
  'direct_manager',
  'transferor',
  'recipient',
  'hr_manager',
  'safety_supervisor',
])
