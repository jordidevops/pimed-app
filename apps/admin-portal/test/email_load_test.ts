// npx tsx --env-file=.env.development test/email_load_test.ts
import { createClient } from '@supabase/supabase-js'

// Llegim les variables de l'entorn (NO les hardcodegem)
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL || 'http://127.0.0.1:54321'
const SUPABASE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY // La clau d'admin
const TENANT_ID = '10000000-0000-0000-0000-000000000001' // Els UUIDs són segurs de pujar a Git

if (!SUPABASE_KEY) {
  console.error('❌ ERROR: No s\'ha trobat SUPABASE_SERVICE_ROLE_KEY a les variables d\'entorn.')
  console.error('Assegura\'t de passar-la al executar l\'script o tenir-la al .env')
  process.exit(1)
}

const supabase = createClient(SUPABASE_URL, SUPABASE_KEY, {
  db: { schema: 'api' }
})

console.log(SUPABASE_KEY);

async function runLoadTest() {
  const TOTAL_EMAILS = 1000
  const BATCH_SIZE = 50

  console.log(`🚀 Iniciant test de càrrega: ${TOTAL_EMAILS} emails...`)
  const startTime = Date.now()

  let successCount = 0
  let errorCount = 0

  for (let i = 0; i < TOTAL_EMAILS; i += BATCH_SIZE) {
    const batch = Array.from({ length: BATCH_SIZE }).map((_, index) => {
      const emailNum = i + index + 1
      return supabase.rpc('enqueue_email', {
        payload: {
          tenant_id: TENANT_ID,
          idempotency_key: `load-test-${Date.now()}-${emailNum}`,
          to: ['delivered@resend.dev'], // Sempre adreça de prova per no gastar quota!
          subject: `Test de Càrrega #${emailNum}`,
          html_body: `<p>Això és un test d'estrès. Missatge número ${emailNum}</p>`,
          priority: 0,
        }
      })
    })

    const results = await Promise.all(batch)
    
    results.forEach(res => {
      if (res.error) {
        errorCount++
        console.error('❌ Error en encuar:', res.error.message)
      } else {
        successCount++
      }
    })

    console.log(`⏳ Processats ${i + BATCH_SIZE} / ${TOTAL_EMAILS}...`)
  }

  const endTime = Date.now()
  console.log('=============================================')
  console.log(`🏁 Test finalitzat en ${(endTime - startTime) / 1000} segons.`)
  console.log(`✅ Èxits (Encuats): ${successCount}`)
  console.log(`❌ Errors: ${errorCount}`)
  console.log('=============================================')
}

runLoadTest()