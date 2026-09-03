# FSR — Guest Table OS (UX visual)

> Part del pack [`README.md`](./README.md).  
> Superfície: `apps/public-portal`, ruta tipus `/t/[token]`.

## Objectiu

Que el comensal senti que **el restaurant va avançat**: transparència del servei (estat + ETA), carta agradable, feedback quan el plat està llest — sense convertir el local en un kiosk QSR ni un backoffice.

## Test del Reel

Criteri de qualitat (no eina tècnica): si un comensal grava **~5 segons** de la pantalla a taula (estil Instagram/TikTok Reel) i, sense context, es veu “aquest restaurant és modern / va amb tecnologia”, **passa**. Si sembla Typeform, Excel o admin SaaS, **falla**.

## Barra visual MVP (Fase 2 — no negociable)

1. **Hero de sessió** — Nom del restaurant + taula + “El vostre sopar” (o dinar).
2. **Timeline de servei** (rail): Comanda enviada → A cuina → Preparant → Llest → Servit. Transicions animades via Broadcast.
3. **ETA dominant** — Número gran creïble (“~12 min”); micro-animació quan canvia.
4. **Carta visual** — Foto + nom + preu + xips d'al·lèrgens; seccions; sold-out ratllat en viu.
5. **Toast / haptic en `ready`** — Moment wow a taula.
6. **Crida cambrer** — Confirmació “Cambrer avisat” lligada a event real (`dining_service_events`).
7. **Tema del tenant** — Colors/logo del public site; aspecte “del local”, no porpra genèric SaaS.
8. **PWA-lite** — Viewport mòbil, tap targets grans, sense chrome d'admin; ambient restaurant opcional.
9. **Offline honest** — Missatge clar + retry si cau la xarxa; no spinner etern.

## Fora del look guest

- Taules HTML denses, SKU, IVA en primer pla
- Botons grisos d'admin / multi-step checkout e-commerce
- Reutilitzar shell visual del portal d'empleat o del lead form

## Motion (mínim 2–3 intencionats)

- Transició d'estat al timeline
- Pulse/canvi de l'ETA
- Entrada del toast `ready`

Sense confetti ni glows decoratius sense funció.

## Accessibilitat i trust

- Contrast llegible amb tema fosc/ambient
- Al·lèrgens llegibles (no només icona)
- Preus clars; sense sorpreses de pagament (MVP sense cobrament a l'app)

## Criteris d'acceptació UX

- [ ] Passa el test del Reel (revisió humana producte/disseny)
- [ ] ETA visible above-the-fold a mòbil
- [ ] Estat `ready` perceptible sense refrescar
- [ ] Crida cambrer mostra confirmació i arriba a Sala
- [ ] Sold-out desapareix/ratlla sense reload manual
