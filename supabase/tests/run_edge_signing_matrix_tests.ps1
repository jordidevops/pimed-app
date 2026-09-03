Param(
  [string]$SupabaseUrl = "http://127.0.0.1:54321",
  [string]$TenantId = "",
  [string]$EdgeJwt = "",
  [string]$HtmlTemplateLocaleId = "",
  [string]$DocxTemplateLocaleId = "",
  [string]$PdfDocumentVersionId = "",
  [string]$HtmlDocumentVersionId = "",
  [string]$DocxDocumentVersionId = "",
  [string]$SignerEmail = "",
  [string]$SignerName = "QA Signer"
)

$ErrorActionPreference = "Stop"

$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$env:SUPABASE_URL = $SupabaseUrl
if ($TenantId)               { $env:EDGE_TEST_TENANT_ID = $TenantId }
if ($EdgeJwt)                { $env:EDGE_TEST_JWT = $EdgeJwt }
if ($HtmlTemplateLocaleId)   { $env:EDGE_TEST_HTML_TEMPLATE_LOCALE_ID = $HtmlTemplateLocaleId }
if ($DocxTemplateLocaleId)   { $env:EDGE_TEST_DOCX_TEMPLATE_LOCALE_ID = $DocxTemplateLocaleId }
if ($PdfDocumentVersionId)   { $env:EDGE_TEST_PDF_DOCUMENT_VERSION_ID = $PdfDocumentVersionId }
if ($HtmlDocumentVersionId)  { $env:EDGE_TEST_HTML_DOCUMENT_VERSION_ID = $HtmlDocumentVersionId }
if ($DocxDocumentVersionId)  { $env:EDGE_TEST_DOCX_DOCUMENT_VERSION_ID = $DocxDocumentVersionId }
if ($SignerEmail)            { $env:EDGE_TEST_SIGNER_EMAIL = $SignerEmail }
if ($SignerName)             { $env:EDGE_TEST_SIGNER_NAME = $SignerName }

Write-Host "Running edge signing matrix tests..." -ForegroundColor Cyan
Write-Host "SUPABASE_URL=$SupabaseUrl" -ForegroundColor DarkGray

node (Join-Path $testsDir 'edge_signing_matrix_tests.mjs')
if ($LASTEXITCODE -ne 0) {
  throw "Edge signing matrix tests failed"
}

Write-Host "Edge signing matrix tests passed." -ForegroundColor Green
