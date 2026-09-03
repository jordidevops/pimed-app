-- =============================================================================
-- Migration: 20260530000005_fix_platform_template_unique_name_per_type.sql
-- Propòsit:  Ampliar l'índex únic idx_doc_templates_platform_name per incloure
--            template_type.
--
--            L'índex original (creat a 20260522000001 abans d'existir el camp
--            template_type) prevenia tenir dues plantilles de plataforma amb el
--            mateix nom, independentment del tipus.
--
--            Ara que existeixen plantilles HTML i DOCX amb els mateixos noms
--            (ex: "Contracte de treball indefinit" en HTML i en DOCX),
--            l'índex ha de permetre (name, template_type) únics, no (name) sol.
--
-- Idempotència: DROP INDEX IF EXISTS + CREATE UNIQUE INDEX.
-- Afecta: ÚNICAMENT l'índex (cap canvi de dades ni de columnes).
-- =============================================================================

-- Eliminar índex antic (només name)
DROP INDEX IF EXISTS data.idx_doc_templates_platform_name;

-- Nou índex: (name, template_type) únics per plantilles de plataforma actives.
-- Permet tenir HTML i DOCX de la mateixa plantilla amb el mateix nom.
CREATE UNIQUE INDEX idx_doc_templates_platform_name
  ON data.document_templates (name, template_type)
  WHERE is_platform_default = true AND is_active = true;

COMMENT ON INDEX data.idx_doc_templates_platform_name
  IS 'Una sola plantilla activa de plataforma per (nom, tipus). Permet HTML i DOCX amb el mateix nom.';
