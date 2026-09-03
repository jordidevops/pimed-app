<#
.SYNOPSIS
    Aplica migraciones de Supabase al entorno indicado.

.DESCRIPTION
    Lee los project-refs desde .supabase-refs y ejecuta `supabase db push`.
    Úsalo en lugar de escribir el ref a mano cada vez.

.PARAMETER Env
    Entorno destino: staging | prod

.EXAMPLE
    .\scripts\db-push.ps1 staging
    .\scripts\db-push.ps1 prod

.NOTES
    Prerrequisito: tener .supabase-refs en la raíz del repo (copia de .supabase-refs.example).
#>

param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("staging", "prod")]
    [string]$Env
)

if (-not $Env) {
    $Env = Read-Host "¿Entorno destino? [staging/prod]"
    if ($Env -notin @("staging", "prod")) {
        Write-Error "Valor incorrecto. Usa 'staging' o 'prod'."
        exit 1
    }
}

$refsFile = Join-Path $PSScriptRoot ".." ".supabase-refs"

if (-not (Test-Path $refsFile)) {
    Write-Error "No se encontró .supabase-refs. Copia .supabase-refs.example y rellena los valores."
    exit 1
}

$refs = Get-Content $refsFile | Where-Object { $_ -match "=" } | ConvertFrom-StringData

$ref = if ($Env -eq "staging") { $refs.STAGING_REF } else { $refs.PROD_REF }

if (-not $ref) {
    Write-Error "El valor ${Env.ToUpper()}_REF está vacío en .supabase-refs."
    exit 1
}

# Asegurarse de ejecutar desde la raíz del proyecto (donde está supabase/config.toml)
$projectRoot = Join-Path $PSScriptRoot ".."
Push-Location $projectRoot

try {
    Write-Host "→ Vinculando proyecto $Env (ref: $ref)..." -ForegroundColor Cyan
    supabase link --project-ref $ref
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Error al vincular el proyecto. Asegúrate de haber ejecutado 'supabase login'."
        exit 1
    }

    Write-Host "→ Aplicando migraciones a $Env (ref: $ref)..." -ForegroundColor Cyan
    supabase db push --linked
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Error al aplicar las migraciones."
        exit 1
    }

    Write-Host "✓ Migraciones aplicadas correctamente a $Env." -ForegroundColor Green
} finally {
    Pop-Location
}
