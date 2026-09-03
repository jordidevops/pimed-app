# Prompt — pla de comunicació interna (transversal)

> **Ús:** enganxeu el bloc següent en una **conversa nova** de Cursor (mode pla) per demanar un estudi/pla de producte separat.  
> **No** forma part de la implementació del mòdul de despeses.  
> Context despeses: aclariments lligats a una despesa ja tenen MVP previst (entity timeline + notificació) a [02-flows-and-surfaces.md](./02-flows-and-surfaces.md) i [03-integrations-ai-comms.md](./03-integrations-ai-comms.md).

---

## Text per enganxar

```text
Vull un pla de producte/arquitectura (només documentació a docs/plans/internal-comms/, sense implementar) per a la comunicació interna a PiMed (pimed-app-supabase).

Context i restriccions:
- Som multi-tenant, multi-vertical (sector_profiles: arquetip + vertical). Apps: tenant-portal (Vite), public-portal (Next, inclou employee portal amb token), Supabase.
- Ja tenim: entity timeline (comentaris, @mentions, read receipts) sobre employee/contact/project/document; notifications in-app + email/SMS/WhatsApp; Resend; portal empleat sense compte Auth obligatori.
- Decisió històrica: no volem competir amb Google Chat, Teams, WhatsApp com a producte de xat general. Però l’app pot quedar coixa si no hi ha cap canal empresa↔empleats ni entre usuaris de l’app.
- Referència externa: Odoo “Enviar mensaje” (persisteix missatge a l’app + notificació email).
- Risc d’identitat dual: un humà pot ser usuari (profiles/auth) i alhora empleat (employees + portal). Cal model clar de canals i bústies per no confondre “missatges de feina com a empleat” vs “col·laboració com a usuari de l’app”.
- El mòdul de despeses farà servir timeline + notificació només per aclariments lligats a una despesa/informe; NO ha d’inventar un xat propi. Veure docs/plans/expenses/.

Objectius del pla:
1. Definir què és in-scope vs out-of-scope (p. ex. fils sobre entitats vs DM globals vs anuncis HR).
2. Proposar 1–2 opcions de producte mínim viable que no intentin substituir Chat/Teams, però cobreixin: demanar aclariments, avisar empleats del portal, i opcionalment missatges curts entre usuaris autenticats.
3. Model de dades/canals, permisos, retenció, i com encaixa amb employee portal (token) vs auth users.
4. Relació amb notificacions existents i amb entity timeline (reutilitzar vs estendre vs nou mòdul).
5. Roadmap per fases i criteris d’acceptació del document.
6. Lliurable: docs/plans/internal-comms/README.md (+ docs necessaris). Enllaçar des de docs/plans/expenses/03-integrations-ai-comms.md.

Preguntes a resoldre al pla (amb decisió recomanada, no llista oberta infinita):
- Només missatgeria lligada a entitats, o també bandeja personal?
- Un sol inbox unificat per persona (fusió user+employee) o safates separades?
- Què es delega deliberadament a WhatsApp/email extern?
```
