/// <reference types="vite/client" />
/// <reference types="vite-plugin-pwa/client" />

interface ImportMetaEnv {
	readonly VITE_SUPPORT_EMAIL?: string
	readonly VITE_SIGNING_HTML_PDF_OUTPUT?: string
	readonly VITE_SENTRY_DSN?: string
	readonly VITE_APP_ENVIRONMENT?: string
}

interface ImportMeta {
	readonly env: ImportMetaEnv
}
