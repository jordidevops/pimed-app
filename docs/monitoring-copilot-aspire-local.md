# Monitoratge local de GitHub Copilot Agents amb OpenTelemetry i Aspire

Data: 2026-05-12  
Abast: només entorn local (Windows), sense persistència històrica entre reinicis  
Audiència: desenvolupadors que treballen amb VS Code + GitHub Copilot

## 1. Objectiu

Aquesta guia explica com:

1. Arrencar Aspire Dashboard en mode standalone.
2. Configurar VS Code perquè Copilot Chat exporti telemetria OpenTelemetry (OTLP HTTP).
3. Veure traces, mètriques i esdeveniments dels agents en local.
4. Validar que la configuració funciona i resoldre incidències habituals.

Important: en mode standalone, Aspire conserva la telemetria en memòria. Si reinicies Aspire, es perden les dades visibles al dashboard.

## 2. Prerequisits

1. VS Code actualitzat amb GitHub Copilot Chat actiu.
2. Docker Desktop en marxa (opció recomanada per iniciar Aspire), o Aspire CLI instal·lat.
3. Ports lliures en local:
- 18888 (UI d'Aspire)
- 4318 (OTLP HTTP)
- 4317 (OTLP gRPC, opcional)

## 3. Quickstart (5 minuts)

1. Inicia Aspire amb Docker:

```powershell
docker run --rm -d `
  -p 18888:18888 `
  -p 4317:18889 `
  -p 4318:18890 `
  --name aspire-dashboard `
  mcr.microsoft.com/dotnet/aspire-dashboard:latest
```

2. Obre el dashboard a http://localhost:18888
3. Obté el token de login des dels logs:

```powershell
docker container logs aspire-dashboard
```

4. A VS Code, configura l'exportador OTel de Copilot perquè enviï a http://localhost:4318.
5. Fes una conversa amb agent mode i executa una acció de codi.
6. Torna a Aspire i verifica traces a la pestanya Traces.

## 4. Arrencada d'Aspire standalone

### Opció A: Docker (recomanada)

Executa:

```powershell
docker run --rm -d `
  -p 18888:18888 `
  -p 4317:18889 `
  -p 4318:18890 `
  --name aspire-dashboard `
  mcr.microsoft.com/dotnet/aspire-dashboard:latest
```

Comprova estat:

```powershell
docker ps --filter "name=aspire-dashboard"
```

Atura i elimina contenidor:

```powershell
docker stop aspire-dashboard
```

### Opció B: Aspire CLI

Executa:

```powershell
aspire dashboard run
```

Mode anònim només per local:

```powershell
aspire dashboard run --allow-anonymous
```

## 5. Configuració de VS Code (settings.json)

Afegeix al teu settings.json de VS Code:

```json
{
  "github.copilot.chat.otel.enabled": true,
  "github.copilot.chat.otel.exporterType": "otlp-http",
  "github.copilot.chat.otel.otlpEndpoint": "http://localhost:4318",
  "github.copilot.chat.otel.captureContent": false,
  "github.copilot.chat.otel.maxAttributeSizeChars": 2000
}
```

Notes:

1. exporterType recomanat: otlp-http.
2. captureContent: false per privacitat (recomanat per defecte).
3. maxAttributeSizeChars evita atributs massa grans quan activis captura de contingut.

## 6. Variables d'entorn (Windows) opcional

Les variables d'entorn tenen prioritat sobre settings.json.

Sessió actual de PowerShell:

```powershell
$env:COPILOT_OTEL_ENABLED = "true"
$env:OTEL_EXPORTER_OTLP_ENDPOINT = "http://localhost:4318"
$env:OTEL_EXPORTER_OTLP_PROTOCOL = "http/protobuf"
$env:OTEL_SERVICE_NAME = "copilot-chat"
$env:OTEL_RESOURCE_ATTRIBUTES = "env=local,team.id=dev,host.name=$env:COMPUTERNAME"
```

Persistència per usuari (nova sessió de terminal):

```powershell
setx COPILOT_OTEL_ENABLED "true"
setx OTEL_EXPORTER_OTLP_ENDPOINT "http://localhost:4318"
setx OTEL_EXPORTER_OTLP_PROTOCOL "http/protobuf"
setx OTEL_SERVICE_NAME "copilot-chat"
setx OTEL_RESOURCE_ATTRIBUTES "env=local,team.id=dev"
```

Després de setx, tanca i obre VS Code perquè llegeixi les noves variables.

## 7. Validació end-to-end

1. Assegura que Aspire està en marxa i accessible a http://localhost:18888.
2. Obre VS Code amb la configuració OTel aplicada.
3. Inicia una sessió de Copilot Chat en agent mode.
4. Executa una petició que impliqui eines (per exemple lectura de fitxers o execució de comandes).
5. A Aspire, obre Traces i busca servei copilot-chat.
6. Verifica spans típics:
- invoke_agent
- chat
- execute_tool

Si també utilitzes sessions CLI de Copilot, pots veure traces separades amb servei github-copilot.

## 8. Diagnosi ràpida (troubleshooting)

### No apareix telemetria

1. Revisa que github.copilot.chat.otel.enabled sigui true.
2. Revisa endpoint OTLP: http://localhost:4318.
3. Revisa exporterType: otlp-http.
4. Comprova que el port 4318 està escoltant (Aspire en marxa).
5. Reinicia VS Code després de canvis de variables d'entorn.

### Error de protocol

1. Si utilitzes OTLP HTTP, mantén exporterType com otlp-http.
2. Si proves gRPC, comprova endpoint i mapatge de port 4317.

### Port ocupat

Detecta ports en ús:

```powershell
Get-NetTCPConnection -LocalPort 18888,4318,4317 -ErrorAction SilentlyContinue | Select-Object LocalPort,State,OwningProcess
```

Canvia mapatge de ports del contenidor si cal.

### No pots entrar al dashboard

1. Revisa logs del contenidor per obtenir URL/token de login:

```powershell
docker container logs aspire-dashboard
```

2. En local de desenvolupament, pots activar mode anònim (no recomanat fora de local).

## 9. Seguretat i privacitat

1. Mantén captureContent desactivat per defecte.
2. Activa captureContent només puntualment per depuració.
3. Recorda que, amb captura de contingut activa, es poden exportar prompts, respostes i dades sensibles de codi.
4. Evita exposar públicament els ports del dashboard en equips no controlats.

## 10. Limitacions conegudes del mode standalone

1. La telemetria es desa en memòria.
2. En reiniciar Aspire es perd l'històric del dashboard.
3. Hi ha límits de retenció en memòria; quan s'assoleixen, es descarten elements antics.

Aquesta guia és intencionalment local-first. Si més endavant necessites retenció persistent i agregació multiordinador, el pas natural és afegir un OpenTelemetry Collector i un backend persistent OSS.

## 11. Referències oficials

1. VS Code: Monitor agent usage with OpenTelemetry  
https://code.visualstudio.com/docs/copilot/guides/monitoring-agents
2. Aspire Dashboard standalone  
https://aspire.dev/dashboard/standalone/
3. Aspire Dashboard configuration  
https://aspire.dev/dashboard/configuration/
