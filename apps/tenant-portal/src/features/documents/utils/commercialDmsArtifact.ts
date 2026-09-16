export function isCommercialDmsArtifact(doc: {
  entity_type?: string | null
} | null | undefined): boolean {
  return doc?.entity_type === 'commercial_document'
}
