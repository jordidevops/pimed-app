-- migration: 20260515000016_lead_ack_copy_email_multi.sql
--
-- Permet emmagatzemar més d'un email a data.public_sites.lead_ack_copy_email,
-- separats per coma o punt-i-coma. Cada element ha de tenir el format minim
-- "<part_local>@<domini>" (sense comes, punts-i-coma ni espais a cap costat de l'@).
--
-- Exemples vàlids:
--   - 'leads@empresa.cat'
--   - 'leads@empresa.cat, comercial@empresa.cat'
--   - 'a@b.com; c@d.com ; e@f.com'
--
-- El worker process-leads-queue parteix la cadena per [,;] abans d'enviar com a BCC.

ALTER TABLE data.public_sites
  DROP CONSTRAINT IF EXISTS chk_public_sites_lead_ack_copy_email;

ALTER TABLE data.public_sites
  ADD CONSTRAINT chk_public_sites_lead_ack_copy_email
    CHECK (
      lead_ack_copy_email IS NULL
      OR lead_ack_copy_email ~* '^\s*[^@,;\s]+@[^@,;\s]+(\s*[,;]\s*[^@,;\s]+@[^@,;\s]+)*\s*$'
    );

COMMENT ON COLUMN data.public_sites.lead_ack_copy_email IS
  'Llista d''emails interns (separats per coma o punt-i-coma) que reben còpia BCC '
  'de cada lead enviat al portal públic. Mai exposat en RPCs anon.';
