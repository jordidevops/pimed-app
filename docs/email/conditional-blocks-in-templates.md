# Plantilles d'email amb Liquid

Les plantilles d'email del sistema fan servir LiquidJS com a motor oficial.

El worker process-email-queue renderitza subject, html_body i text_body amb el mateix motor shared (liquid-renderer), de manera consistent amb la resta de canals de plantilles.

---

## Sintaxi disponible

### Interpolacio de variables

```liquid
Hola {{ signer_name }}
```

### Condicionals

```liquid
{% if signer_role %}
<p>El teu rol: <strong>{{ signer_role }}</strong></p>
{% endif %}
```

### Condicional negada

```liquid
{% unless signing_url %}
<p>No s ha pogut generar la URL de signatura.</p>
{% endunless %}
```

### Iteracio

```liquid
{% for signer in signers %}
<li>{{ signer.name }} ({{ signer.email }})</li>
{% endfor %}
```

---

## Ordre de renderitzat

1. El worker resol les traduccions/plantilla activa.
2. Renderitza cada camp de text amb Liquid.
3. Si hi ha layout, renderitza el layout amb les variables finals.

No hi ha pipeline de regex ni passos separats renderConditionals/renderTemplate.

---

## Variables habituals de signing

| Variable | Descripcio |
|----------|------------|
| signer_name | Nom del destinatari |
| signer_email | Correu del destinatari |
| signer_role | Rol del signant |
| signing_url | URL de signatura |
| document_title | Titol del document |
| current_order | Ordre actual de signatura |
| total_signers | Nombre total de signants |

---

## Compatibilitat i regles

1. La sintaxi legacy d estil Handlebars no es considera valida per a noves plantilles.
2. Els blocs antics {{#if}}, {{/if}}, {{#unless}}, {{/unless}} no s han d usar.
3. Els editors i les validacions de dades bloquegen la persistencia de sintaxi legacy.

Exemple incorrecte:

```handlebars
{{#if signer_role}}...{{/if}}
```

Exemple correcte:

```liquid
{% if signer_role %}...{% endif %}
```

---

## Bones practiques

1. Usa claus estables i en minuscules amb underscore.
2. Mantingues la logica simple a plantilla (if/for bàsics).
3. Si una variable pot no existir, protegeix la UI amb if o unless.
4. Valida la sintaxi Liquid abans de desar canvis.
