export type CommercialDecisionPublicLocale = 'ca' | 'es' | 'en'

type Copy = {
  budget: string
  amendment: string
  delivery: string
  agreement: string
  consequenceQuote: string
  consequenceAgreement: string
  consequenceDelivery: string
  accepted: string
  declined: string
  registeredAt: string
  registeredOk: string
  signer: string
  reason: string
  hideReceipt: string
  showReceipt: string
  receiptTitle: string
  issuer: string
  document: string
  outcome: string
  dateUtc: string
  via: string
  provider: string
  hash: string
  trace: string
  downloadPdf: string
  expiredTitle: string
  expiredBody: string
  revokedTitle: string
  supersededTitle: string
  contactIssuer: string
  validUntil: string
  expires: string
  pdfPreparing: string
  fullName: string
  authority: string
  acceptSign: string
  refuse: string
  refuseTitle: string
  reasonOptional: string
  back: string
  confirmRefuse: string
  saving: string
  processing: string
  privacySummary: string
  privacyBody: string
  needNameAuthority: string
  acceptFailed: string
  refuseFailed: string
  documentFallback: string
  continueDocuseal: string
  continueDocusealHint: string
  waitingProvider: string
  providerPending: string
  continueFailed: string
}

const CA: Copy = {
  budget: 'Pressupost',
  amendment: 'Ampliació',
  delivery: 'Albarà',
  agreement: 'Acord',
  consequenceQuote: 'Acceptes aquesta oferta i les seves condicions.',
  consequenceAgreement: 'Signes aquest acord i el pressupost annex.',
  consequenceDelivery: 'Confirmes la recepció/execució descrita.',
  accepted: 'Acceptat',
  declined: 'Refusat',
  registeredAt: 'Registrat el {{when}}',
  registeredOk: 'La resposta s’ha registrat correctament.',
  signer: 'Signant',
  reason: 'Motiu',
  hideReceipt: 'Amagar justificant',
  showReceipt: 'Veure justificant',
  receiptTitle: 'Justificant de resposta',
  issuer: 'Emissor',
  document: 'Document',
  outcome: 'Resultat',
  dateUtc: 'Data (UTC)',
  via: 'Via',
  provider: 'Proveïdor',
  hash: 'Hash',
  trace: 'Traça',
  downloadPdf: 'Descarregar PDF del document',
  expiredTitle: 'Enllaç caducat',
  expiredBody: 'Demana un nou enllaç a l’emissor.',
  revokedTitle: 'Enllaç revocat',
  supersededTitle: 'Versió substituïda',
  contactIssuer: 'Contacta amb l’emissor si necessites un enllaç nou.',
  validUntil: 'Vàlid fins {{date}}',
  expires: 'Caduca {{date}}',
  pdfPreparing: 'El PDF s’està preparant…',
  fullName: 'Nom i cognoms',
  authority: 'He revisat el document i tinc autoritat per acceptar-lo.',
  acceptSign: 'Acceptar i signar',
  refuse: 'Refusar',
  refuseTitle: 'Refusar',
  reasonOptional: 'Motiu (opcional)',
  back: 'Enrere',
  confirmRefuse: 'Confirmar refús',
  saving: 'Desant…',
  processing: 'Processant…',
  privacySummary: 'Informació de privacitat',
  privacyBody:
    'La resposta es registra amb l’hora, el document i el canal d’accés per a la traçabilitat comercial. No es mostren dades tècniques sensibles al client. El responsable del tractament és l’emissor del document; contacta’l per a més informació (Art. 13 RGPD).',
  needNameAuthority: 'Cal el nom i confirmar que tens autoritat per acceptar.',
  acceptFailed: 'No s’ha pogut acceptar',
  refuseFailed: 'No s’ha pogut refusar',
  documentFallback: 'Document',
  continueDocuseal: 'Continuar a DocuSeal',
  continueDocusealHint:
    'Revisaràs i signaràs el document en un servei extern. Quan acabis, torna a aquesta pàgina si cal.',
  waitingProvider: 'Processant la resposta del proveïdor…',
  providerPending: 'L’enllaç de firma encara no està llest. Torna-ho a provar en uns segons.',
  continueFailed: 'No s’ha pogut obrir DocuSeal',
}

const ES: Copy = {
  ...CA,
  budget: 'Presupuesto',
  amendment: 'Ampliación',
  delivery: 'Albarán',
  agreement: 'Acuerdo',
  consequenceQuote: 'Aceptas esta oferta y sus condiciones.',
  consequenceAgreement: 'Firmas este acuerdo y el presupuesto anexo.',
  consequenceDelivery: 'Confirmas la recepción/ejecución descrita.',
  accepted: 'Aceptado',
  declined: 'Rechazado',
  registeredAt: 'Registrado el {{when}}',
  registeredOk: 'La respuesta se ha registrado correctamente.',
  signer: 'Firmante',
  reason: 'Motivo',
  hideReceipt: 'Ocultar justificante',
  showReceipt: 'Ver justificante',
  receiptTitle: 'Justificante de respuesta',
  issuer: 'Emisor',
  document: 'Documento',
  outcome: 'Resultado',
  dateUtc: 'Fecha (UTC)',
  via: 'Vía',
  provider: 'Proveedor',
  hash: 'Hash',
  trace: 'Traza',
  downloadPdf: 'Descargar PDF del documento',
  expiredTitle: 'Enlace caducado',
  expiredBody: 'Pide un nuevo enlace al emisor.',
  revokedTitle: 'Enlace revocado',
  supersededTitle: 'Versión sustituida',
  contactIssuer: 'Contacta con el emisor si necesitas un enlace nuevo.',
  validUntil: 'Válido hasta {{date}}',
  expires: 'Caduca {{date}}',
  pdfPreparing: 'El PDF se está preparando…',
  fullName: 'Nombre y apellidos',
  authority: 'He revisado el documento y tengo autoridad para aceptarlo.',
  acceptSign: 'Aceptar y firmar',
  refuse: 'Rechazar',
  refuseTitle: 'Rechazar',
  reasonOptional: 'Motivo (opcional)',
  back: 'Atrás',
  confirmRefuse: 'Confirmar rechazo',
  saving: 'Guardando…',
  processing: 'Procesando…',
  privacySummary: 'Información de privacidad',
  privacyBody:
    'La respuesta se registra con la hora, el documento y el canal de acceso para la trazabilidad comercial. No se muestran datos técnicos sensibles al cliente. El responsable del tratamiento es el emisor del documento; contáctalo para más información (Art. 13 RGPD).',
  needNameAuthority: 'Hace falta el nombre y confirmar que tienes autoridad para aceptar.',
  acceptFailed: 'No se ha podido aceptar',
  refuseFailed: 'No se ha podido rechazar',
  documentFallback: 'Documento',
  continueDocuseal: 'Continuar en DocuSeal',
  continueDocusealHint:
    'Revisarás y firmarás el documento en un servicio externo. Cuando termines, vuelve a esta página si hace falta.',
  waitingProvider: 'Procesando la respuesta del proveedor…',
  providerPending: 'El enlace de firma aún no está listo. Inténtalo de nuevo en unos segundos.',
  continueFailed: 'No se ha podido abrir DocuSeal',
}

const EN: Copy = {
  ...CA,
  budget: 'Quote',
  amendment: 'Amendment',
  delivery: 'Delivery note',
  agreement: 'Agreement',
  consequenceQuote: 'You accept this offer and its terms.',
  consequenceAgreement: 'You sign this agreement and the attached quote.',
  consequenceDelivery: 'You confirm the described receipt/execution.',
  accepted: 'Accepted',
  declined: 'Declined',
  registeredAt: 'Recorded on {{when}}',
  registeredOk: 'Your response was recorded successfully.',
  signer: 'Signer',
  reason: 'Reason',
  hideReceipt: 'Hide receipt',
  showReceipt: 'View receipt',
  receiptTitle: 'Response receipt',
  issuer: 'Issuer',
  document: 'Document',
  outcome: 'Outcome',
  dateUtc: 'Date (UTC)',
  via: 'Via',
  provider: 'Provider',
  hash: 'Hash',
  trace: 'Trace',
  downloadPdf: 'Download document PDF',
  expiredTitle: 'Link expired',
  expiredBody: 'Ask the issuer for a new link.',
  revokedTitle: 'Link revoked',
  supersededTitle: 'Superseded version',
  contactIssuer: 'Contact the issuer if you need a new link.',
  validUntil: 'Valid until {{date}}',
  expires: 'Expires {{date}}',
  pdfPreparing: 'Preparing the PDF…',
  fullName: 'Full name',
  authority: 'I have reviewed the document and have authority to accept it.',
  acceptSign: 'Accept and sign',
  refuse: 'Decline',
  refuseTitle: 'Decline',
  reasonOptional: 'Reason (optional)',
  back: 'Back',
  confirmRefuse: 'Confirm decline',
  saving: 'Saving…',
  processing: 'Processing…',
  privacySummary: 'Privacy information',
  privacyBody:
    'The response is recorded with the time, document and access channel for commercial traceability. Sensitive technical data is not shown to the client. The data controller is the document issuer; contact them for more information (GDPR Art. 13).',
  needNameAuthority: 'Name and authority confirmation are required to accept.',
  acceptFailed: 'Could not accept',
  refuseFailed: 'Could not decline',
  documentFallback: 'Document',
  continueDocuseal: 'Continue to DocuSeal',
  continueDocusealHint:
    'You will review and sign the document in an external service. When you finish, return to this page if needed.',
  waitingProvider: 'Processing the provider response…',
  providerPending: 'The signing link is not ready yet. Try again in a few seconds.',
  continueFailed: 'Could not open DocuSeal',
}

export function commercialDecisionPublicLocale(
  raw: string | null | undefined,
): CommercialDecisionPublicLocale {
  const v = (raw || 'ca').toLowerCase().slice(0, 2)
  if (v === 'es') return 'es'
  if (v === 'en') return 'en'
  return 'ca'
}

export function commercialDecisionPublicCopy(
  locale: string | null | undefined,
): Copy {
  const key = commercialDecisionPublicLocale(locale)
  if (key === 'es') return ES
  if (key === 'en') return EN
  return CA
}

export function fillCopy(template: string, vars: Record<string, string>): string {
  return Object.entries(vars).reduce(
    (acc, [k, v]) => acc.replaceAll(`{{${k}}}`, v),
    template,
  )
}
