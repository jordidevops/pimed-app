# Fase 5 — Ordres de canvi (opcional / diferible)

> **Ordre:** 5 · **Depèn de:** CF-9 ✅ · fases 1–4 recomanades · **No bloqueja** V1 CF-22  
> **Índex:** [`README.md`](./README.md) · O-D3, O-D4

## Objectiu honest

CF-9 **ja** és l’ordre de canvi: ampliació acceptada → `authorized_total` puja → seguiment (fase 4) es refresca. El PDF d’acord annexat **no** es regenera sol (CT-D7/D8).

Aquesta fase **no** inventa re-firma automàtica. Només tanca el forat d’UX perquè l’oficina no cregui que l’acord PDF reflecteix l’ampliació.

## Què fer (mínim)

- [ ] Després d’acceptar `quote_amendment` en un projecte amb acord `project` actiu: banner a OS/acord — «L’import autoritzat ha canviat. L’annex del contracte no s’ha actualitzat.»
- [ ] CTA: enllaç a prepare / «Preparar nova versió» **manual** (flux CT existent: nova versió + firma). Sense auto-prepare.
- [ ] Copy a fites: si contractat puja, les fites **no** s’inflen soles; oficina pot crear **nova versió** d’acord i redefinir fites (O-D13).
- [ ] Tests: accept amendment no crida prepare.

## Què NO fer

- Trigger accept → prepare_agreement.
- Mutar PDF firmat.
- Entitat `change_order` paral·lela.
- Reobrir CT-D7 («Acceptar no crea acord»).

## DoD (si s’implementa)

- [ ] Banner + CTA visibles en smoke.
- [ ] Documentat a STATUS com a CF-22-5 ✅ o diferit explícit al checklist.

## Si es difereix

Al tancar CF-22 V1 (fases 1–4+6), deixar al CHECKLIST: «Fase 5 diferida — ampliació actualitza authorized_total; annex PDF pot quedar stale.» Això **no** impedeix marcar el criteri Tall 3 #5 si UAT demostra ampliació signada (el document signat és el quote_amendment, no el PDF d’acord).
