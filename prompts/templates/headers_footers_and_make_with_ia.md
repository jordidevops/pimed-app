## Prompt pel pla header_footer_doc_templates.md

La app té plantilles de correu que es poden configurar a /settings/email pestanya Plantilles. Les plantilles utilitzen uns Layouts globals. El layout és el marc visual (capçalera, peu de pàgina, colors) que embolcalla totes les plantilles de correu. 
La app també té plantilles de documents que poden ser en format HTML o en format DOCX. Aquestes plantilles de document potser també podrien tenir un manera de configurar un header o footer aplicable a totes, sigui a nivell de tenant o de site. En el cas de plantilles html la solució podria ser utilitzar un layout global con es fa en les plantilles de correu, però potser per integrar els dos formats potser l'ideal és utilitzar unes etiquetes  especials per header i footer (i altres que poguin convenir) i que es poguin crear i editar blocs de contingut per ser substituits en cada etiqueta si l'usuari o selecciona en la mateixa pantalla en que es substituiexen les etiquetes de variables. S'hauria de guardar per cada plantilla l'opció escollida per no haver de seleccionar cada cop el bloc i activar-lo. Aquest blocs pdrien contenir també etiquetes globals per ser subtiuides per valors del tenant, per exemple nom del tenant, nom del site, etc.
Fes un estudi sobre les opcions i viabilitat d'aquest sistema en cada format de plantilla de document, HTML i DOCX, elabora un pla de implementació i guarda'l al document header_footer_doc_templates.md.



## Prompt pel pla make_templates_with_ia.md

La app permet crear plantilles de documents a /documents/templates i després a cada plantilla, a /documents/templates/<uid>, afegir-li idiomes (locales). Però els tenants no crearan el contingut dels locales a mà, utilitzaran models de IA. La app ha de proporcionar prompts d'exemple per a generar plantilles de documents de tipus HTML o DOCX. El prompt explica a la IA el funcionament de les plantilles, les etiquetes disponibles a la app pel context de roles, de firmes, i l'usuari només haurà de substituir en el prompt l'apartat on explica exactament el que vol. El sistema de plantilles hauria d'estar pensat per a que faciliti aquesta feina a usuari i IA. A la app estaria bé un centre de confecció de plantilles on es poden veure i copiar els prompts, es poden enganxar els valors de plantilles i jsons i veure una vista prèvia del resultat, és a dir com en el modal "Generar document", poden omplir el Context de dades, les variables i veient la vista prèvia.
Ara tenim un editor de locales on falta la vista prèvia. Estari bé una solució en la que es pogués carregar un json creat per la IA que omplis Codi d'idioma, Contingut HTML (raw), Rols de document, i Variables de la plantilla. El prompt explicaria a la IA el format de sortida json necesari, que podria incorporar varis locales donat la facilitat de la IA per traduir. Contemplem inicialment que el prompt s'enganxa a una IA externa, però idealment tota hauria de passar a la app si el tenant té configurada una api key de models IA i es pot fer directament al crida per api. Aquesta opció d'utilitzar a la app la IA amb crides api a OpenIA, Gemini, Claude, etc mereix un pla apart que de moment deixem de costat però que cal considerar que sí o sí tindrem aquesta funcionalitat com opcional.
Es una proposta. Estudia-ho, busca la millor solució, fes un pla d'implementació i guarda'l a l'arxiu make_templates_with_ia.md.


Però el prompt ha d'informar a la IA dels rols per defecte disponibles que es troben a /settings/templates tab plantilles (worker
manager
approver
reviewer
requester
transferor
recipient
external_party
legal_representative
hr_manager
direct_manager
hr_director
payroll_responsible
technician
safety_supervisor
site_manager
warehouse_manager
asset_custodian
service_item
product_item
client_signatory
supplier_signatory
customer
vendor
contractor
partner
compliance_officer), el tipus d'entitat, com employee, i que per cada entitat podem utilitzar etiquetes de les seves columnes, per exemple per worker 
Nom complet {{worker.full_name}}
Email {{worker.email}}
Telèfon {{worker.phone}}
Càrrec {{worker.job_title}}
NIF/DNI {{worker.document_id}}
Data incorporació {{worker.starts_on}}
Estat {{worker.status}}
Això es veu a l'editor d'idiomes actual on si creem un "Rols de document" amb Nom del rol, Etiqueta, Entitat, Ord. i Signa, apareixen Camps per entitat i Variables globals per ajudar a l'usuari.