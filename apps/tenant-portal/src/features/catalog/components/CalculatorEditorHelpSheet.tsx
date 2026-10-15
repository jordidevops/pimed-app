import { useTranslation } from 'react-i18next'
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
} from '@/components/ui/sheet'

type Props = {
  open: boolean
  onOpenChange: (open: boolean) => void
}

export function CalculatorEditorHelpSheet({ open, onOpenChange }: Props) {
  const { t } = useTranslation(['catalog', 'common'])

  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent
        side="right"
        className="flex w-full flex-col gap-0 overflow-hidden p-0 sm:max-w-lg"
      >
        <SheetHeader className="shrink-0 border-b border-border px-4 py-3">
          <SheetTitle>
            {t('catalog.calculators.help_title', 'Com funciona una calculadora')}
          </SheetTitle>
          <SheetDescription>
            {t(
              'catalog.calculators.help_sheet_desc',
              'Raonament, exemple guiat i com construir-la amb IA o amb els assistents.',
            )}
          </SheetDescription>
        </SheetHeader>
        <div className="min-h-0 flex-1 space-y-6 overflow-y-auto px-4 py-4 text-sm">
          <section className="space-y-2">
            <h3 className="font-semibold">
              {t('catalog.calculators.help_what_title', 'Què és')}
            </h3>
            <p className="text-muted-foreground">
              {t(
                'catalog.calculators.help_what_body',
                'Una calculadora és una plantilla que, en entrar valors, genera les línies del full de preus del pressupost (el mateix tipus de línies que afegiries a mà, però amb fórmules i tarifes). Quan l'utilitzes només omples els paràmetres en un formulari.',
              )}
            </p>
          </section>

          <section className="space-y-2">
            <h3 className="font-semibold">
              {t('catalog.calculators.help_reason_title', 'Raonament comercial')}
            </h3>
            <p className="text-muted-foreground">
              {t(
                'catalog.calculators.help_reason_body',
                'Pensa primer què vols cobrar (les línies del pressupost) i de què depèn. Després, a l’editor, construeixes en ordre dades → línies: paràmetres (el que demanes), constants (preus fixos), línies, i taules si calen trams. Els assistents enllacen peces ja creades (p. ex. «Preu (constant)»), per això no es pot materialitzar la línia abans d’existir la tarifa.',
              )}
            </p>
            <p className="text-muted-foreground">
              {t(
                'catalog.calculators.help_reason_table',
                'La taula només guarda files i columnes; quina columna s’usa es decideix a la línia (lookup). Sense una línia que la llegeixi, la taula no afecta el total.',
              )}
            </p>
          </section>

          <section className="space-y-2">
            <h3 className="font-semibold">
              {t(
                'catalog.calculators.help_example_title',
                'Exemple de les pastilles: Desplaçament + mà d’obra',
              )}
            </h3>
            <ul className="list-disc space-y-1 pl-5 text-muted-foreground">
              <li>
                {t(
                  'catalog.calculators.help_example_params',
                  'Paràmetres: distance_km (Distància), hours (Hores).',
                )}
              </li>
              <li>
                {t(
                  'catalog.calculators.help_example_const',
                  'Constant: labor_eur_h («€/hora mà d’obra») = 45.',
                )}
              </li>
              <li>
                {t(
                  'catalog.calculators.help_example_table',
                  'Taula travel (trams km): max_km → eur_base (15→0, 40→35, més enllà→55).',
                )}
              </li>
              <li>
                {t(
                  'catalog.calculators.help_example_lines',
                  'Línies: «Mà d’obra» (hours × labor_eur_h). Desplaçament: Distància × €/km, o import fix per trams (qty 1).',
                )}
              </li>
              <li>
                {t(
                  'catalog.calculators.help_example_preview',
                  'Previsualitza p. ex. 2 h i 25 km: veuràs les dues línies i el total.',
                )}
              </li>
            </ul>
            <p className="text-muted-foreground">
              {t(
                'catalog.calculators.help_example_extras',
                'Altres pastilles (potència, €/l…) són peces soltes, no un segon tutorial complet.',
              )}
            </p>
          </section>

          <section className="space-y-2">
            <h3 className="font-semibold">
              {t('catalog.calculators.help_ai_steps_title', 'Pas a pas amb IA')}
            </h3>
            <ol className="list-decimal space-y-1.5 pl-5 text-muted-foreground">
              <li>
                {t(
                  'catalog.calculators.help_ai_1',
                  'Paràmetres → «Proposar amb IA» → pastilla «Distància km», després «Hores». Deixa marcat revisar al modal i confirma.',
                )}
              </li>
              <li>
                {t(
                  'catalog.calculators.help_ai_2',
                  'Constants → pastilla «€/hora» → revisa valor i Desa.',
                )}
              </li>
              <li>
                {t(
                  'catalog.calculators.help_ai_3',
                  'Línies → pastilla «Mà d’obra» (usa hours i labor_eur_h).',
                )}
              </li>
              <li>
                {t(
                  'catalog.calculators.help_ai_travel',
                  'Desplaçament: botó «Desplaçament…» (€/km o trams) o pastilles «Desplaçament €/km» / «Desplaçament trams».',
                )}
              </li>
              <li>
                {t(
                  'catalog.calculators.help_ai_4',
                  'Si tries trams: Taules → pastilla «Trams km» (si no l’ha creat l’assistent).',
                )}
              </li>
              <li>
                {t(
                  'catalog.calculators.help_ai_6',
                  'Omple la previsualització, desa la prova i activa quan estigui verd.',
                )}
              </li>
            </ol>
          </section>

          <section className="space-y-2">
            <h3 className="font-semibold">
              {t(
                'catalog.calculators.help_wizard_steps_title',
                'Pas a pas amb assistents (sense IA)',
              )}
            </h3>
            <ol className="list-decimal space-y-1.5 pl-5 text-muted-foreground">
              <li>
                {t(
                  'catalog.calculators.help_wiz_1',
                  'Paràmetres → Afegir: Distància (distance_km) i Hores (hours).',
                )}
              </li>
              <li>
                {t(
                  'catalog.calculators.help_wiz_2',
                  'Constants → Afegir tarifa: etiqueta «€/hora…», clau labor_eur_h, valor 45.',
                )}
              </li>
              <li>
                {t(
                  'catalog.calculators.help_wiz_3',
                  'Línies → plantilla fixa: qty = Hores (hours), Preu (constant) = €/hora (labor_eur_h).',
                )}
              </li>
              <li>
                {t(
                  'catalog.calculators.help_wiz_4',
                  'Taules → tier, input Distància, columnes max_km i eur_base, files d’exemple.',
                )}
              </li>
              <li>
                {t(
                  'catalog.calculators.help_wiz_5',
                  'O botó «Desplaçament…»: €/km (es veuen els km) o trams (import fix).',
                )}
              </li>
              <li>
                {t(
                  'catalog.calculators.help_wiz_6',
                  'Previsualitza, desa cas i activa.',
                )}
              </li>
            </ol>
          </section>

          <section className="space-y-2">
            <h3 className="font-semibold">
              {t('catalog.calculators.help_ast_title', 'AST / Avançat')}
            </h3>
            <p className="text-muted-foreground">
              {t(
                'catalog.calculators.help_ast_body',
                '«Avançat (AST)» edita expressions per blocs (param, const_ref, lookup, tier…). Prefereix assistent o IA; l’exemple de les pastilles no necessita AST. Si una línia ja té expressió complexa, es mostra com a només lectura fins que l’obris a Avançat.',
              )}
            </p>
          </section>

          <section className="space-y-2">
            <h3 className="font-semibold">
              {t('catalog.calculators.help_activate_title', 'Prova i activació')}
            </h3>
            <p className="text-muted-foreground">
              {t(
                'catalog.calculators.help_activate_body',
                'Omple tarifes incompletes (assumed). Desa almenys un cas verd des de la previsualització. Publica i activa: aleshores la calculadora surt al flux ràpid i als fulls de preus.',
              )}
            </p>
          </section>
        </div>
      </SheetContent>
    </Sheet>
  )
}
