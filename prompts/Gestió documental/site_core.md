Site Core

Site no es “guardar PDFs”, sino construir un repositorio legal-operativo audit-ready que responda en segundos a estas preguntas:
¿Qué documentación debe existir en este restaurante?
¿Qué está vigente, qué caduca y qué falta?
¿Qué proveedor / equipo / instalación soporta cada requisito?
¿Qué le enseño hoy a un inspector sin buscar en carpetas?

Site debe ser una capa documental normativa, conectada con proveedores, instalaciones, activos y obligaciones por comunidad autónoma/municipio.

Site = expediente vivo del restaurante
No organizado por carpetas sueltas, sino por objetos funcionales:
Restaurante
Instalación / sistema
Ej.: PCI, climatización, extracción, agua, videovigilancia, gas, electricidad, cámaras frigoríficas
Activo / equipo
Ej.: freidora, lavavajillas, campana, extintor
Proveedor / mantenedor
Contrato
Obligación / requisito
Documento / evidencia
Inspección / visita
Calendario de renovaciones y revisiones
La clave: el documento nunca vive solo. Siempre debe estar enlazado a uno o varios de estos objetos.

Vista principal: “Estado legal del local”
Un panel muy simple:
Verde: completo y vigente
Ámbar: próximo a vencer / revisión próxima / documento pendiente de validar
Rojo: falta documento crítico o está caducado
Con 4 bloques fijos:
Licencias y actividad
Instalaciones obligatorias
Contratos y mantenedores
Inspecciones y evidencias

El objetivo de Site debe ser que la respuesta a esta pregunta sea siempre, SI.
¿Estamos listos para una inspección hoy?

Vista “Qué me falta”
No una carpeta, sino una lista accionable:
Falta contrato vigente PCI
Falta certificado última revisión cámaras frigoríficas
Falta evidencia limpieza trimestral campanas
Falta cartel / registro / política de videovigilancia
Falta documento sanitario/autocontrol aplicable al local

Vista “Expediente de inspección”
Un botón único:
“Generar expediente del local”
Que monte un dossier filtrable por:
Laboral 
Sanitario
Industria / instalaciones
PRL
Protección de datos
Licencias / apertura / actividad
Medio ambiente / residuos
Incendios

cada instalación/equipo con estado, click y ves:
proveedor
contrato
próximas revisiones
últimas evidencias
documentos vigentes
incidencias abiertas en Operations
Aquí está el puente real entre Site y Operations.

Estructura funcional recomendada para Site

Yo no usaría una única taxonomía. Usaría doble estructura:

Capa 1. Estructura por “dominio legal”
Es la que le habla al negocio:
Licencias y habilitaciones
licencia / declaración responsable / título habilitante
escritura o datos societarios vinculados
CIF/NIF sociedad
seguro del local / RC
proyecto técnico y anexos relevantes
aforo, actividad autorizada, horario si aplica
Laboral
CNAE
Contratos, DNI, % contrato indefinido, % Diversidad funcional
Seguridad alimentaria y autocontrol
Instalaciones técnicas
PCI
electricidad BT
climatización / RITE si aplica
extracción y campanas
frío industrial / cámaras
agua / ACS / sistemas con riesgo legionella si aplican
ascensores / montacargas si existen
sistemas de alarma / intrusión / CCTV
Mantenimiento obligatorio
contrato vigente
alcance del servicio
periodicidad
SLA / tiempos de respuesta
empresa habilitada / acreditada cuando aplique
persona de contacto
anexos técnicos
facturas o partes, solo si aportan valor probatorio
certificado inicial
revisiones periódicas
boletines
partes de mantenimiento
actas de inspección
subsanaciones
PRL y seguridad
evaluaciones de riesgo
formación
planes de emergencia/autoprotección si aplican
simulacros / revisiones
coordinación de actividades empresariales con terceros, cuando proceda
Protección de datos y videovigilancia
registro interno/soporte documental del tratamiento
cartel y capa informativa
contrato con proveedor 
política de conservación / acceso
ubicación cámaras y finalidad
Residuos y medio ambiente
recogida de basuras
tratamiento de aceite
separación residuos en el restaurante 
Contratos y terceros
Financiero
información sobre los números de cuenta de cada site
contrato préstamo o leasing activos con condiciones económicas (resumen de importe, cuotas, coste financiero,...)
comisiones:
datáfonos 
servicios financieros
Inspecciones, actas y subsanaciones
acta
requerimiento
evidencia aportada
responsable
fecha límite
estado de subsanación


Capa 2. Estructura por “objeto”
Es la que le habla al sistema:
local
instalación
equipo
proveedor
contrato
requisito
documento
revisión
incidencia
inspección

La primera capa es navegable. La segunda da consistencia al dato.

El gran cambio: no guardar “documentos”, sino “requisitos”
Esta es la parte innovadora , cada local tendría una matriz de requisitos:
requisito
categoría
criticidad
ámbito geográfico
 (España / comunidad autónoma / municipio / centro comercial / marca)
desencadenante
 (si tiene luz, si tiene campana, si tiene torre, si hay CCTV, si tiene terraza, si hay música, etc.)
periodicidad
evidencia exigida
propietario interno
proveedor relacionado
estado actual


Ejemplo:
Requisito: revisión PCI
 Aplica si: local tiene instalación PCI
 Periodicidad: anual / según activo / según normativa
 Evidencia aceptada: certificado revisión + parte + empresa mantenedora habilitada
 Responsable: Site
 Ejecución / aviso: proveedor + gerente
 Conexión con Operations: si hay defecto, abrir incidencia correctiva
Así dejas de pensar en carpetas y pasas a pensar en cumplimiento comprobable.

Construir Site como una mezcla de:
DMS estructurado
motor de cumplimiento
repositorio por proveedor
expediente por restaurante
y disparador de acciones hacia Operations

Qué innovaría de verdad

1. “Expediente vivo”
El botón que genera automáticamente el expediente de inspección por local, con índice, vigencias y faltantes.

2. “Aplicabilidad automática”
Cuando marcas que un local tiene luz, extracción, videovigilancia o legionella, el sistema activa automáticamente los requisitos documentales relacionados.

3. “Documento único, múltiples impactos”
Subes una revisión de campanas y automáticamente:
actualiza Site
cierra un vencimiento
deja evidencia histórica
y, si detecta defecto, abre incidencia en Operations

4. “IA inspector”
Chat interno tipo:
“¿Qué me falta para sanidad en este local?”
“Enséñame la última revisión PCI”
“¿Qué contratos vencen este mes en 98?”
