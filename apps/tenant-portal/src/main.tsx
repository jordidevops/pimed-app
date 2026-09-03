import React from 'react'
import ReactDOM from 'react-dom/client'
import { BrowserRouter } from 'react-router-dom'
import App from './App.tsx'
import './index.css'
import './locales/i18n';
import { bootstrapObservability, ObservabilityErrorBoundary } from './lib/observability'
import { registerSW } from 'virtual:pwa-register'

bootstrapObservability()

registerSW({ immediate: true })

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <ObservabilityErrorBoundary>
      <BrowserRouter future={{ v7_startTransition: true, v7_relativeSplatPath: true }}>
        <App />
      </BrowserRouter>
    </ObservabilityErrorBoundary>
  </React.StrictMode>,
)
