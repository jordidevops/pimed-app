# CF-29 — Riscos

Cada fase el cobreix al seu checklist. Això és el mapa.

| Risc | Què el tanca |
|------|----------------|
| Avaluador que acaba sent `eval` | D5. AST tancat, límits de nodes, validador strict. El servidor no confia en el JSON del client: l’Edge el torna a validar i a executar. |
| L’esquema creix sense versió | `schema_version`. Una op nova no entra a la fase 8; és un altre pla. |
| Fórmula que falla en silenci i escriu 0 | `division_by_zero`, `lookup_miss`, `tariff_incomplete` buiden les línies. Preu 0 només amb `allow_zero_price` (D6). |
| Preus no revisats | D12. Null o `assumed` bloqueja `active`. La biblioteca no porta imports. La fase 7 exigeix confirmar cada número nou. |
| Cost d’IA | Mateix ledger i els mateixos límits (tokens, no euros). Sense adjunt a la fase 7. El cost per generació no s’ha mesurat; és el d’un composer JSON curt. |
| Portal i servidor no coincideixen | D14. Hash SHA-256. Si difereix, zero escriptures. Fixtures compartides a Vitest i Deno. |
| Un cèntim de diferència amb el full de preus | D10. La previsualització usa els dos passos de l’emissió. La vista només es toca si el spike troba un vector real. |
| `apply_price_sheet` en mode replace esborra totes les línies | Prohibit en aquest camí (fase 2). |
| El document 06 es pren com a estat de V2 | El README de l’epic diu que el codi mana: V2 emet i no crea OS sola. |
| Injecció de prompt | La fase 7 no dona tools al model. El validador és la frontera. Sense fitxers pujats. |
| Un tècnic executa preus lliures sense permís | D7. Executar exigeix `commercial.pricing.edit`. La RPC d’escriptura no és cridable per `authenticated`. |
| La traça mor en emetre o en crear l’OS | La fase 2 copia les columnes d’origen als dos sentits. |
| Re-executar esborra una línia que l’usuari ha editat | La fase 6 passa aquella fila a `manual` i la treu del grup. |
