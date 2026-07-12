# ============================================================
# INSTALACIÓN AUTOMÁTICA DE VAULTWARDEN EN DOCKER DESKTOP
# Windows 10 / PowerShell
# ============================================================

$InstallDir = Join-Path $HOME "Docker\Vaultwarden"
$ComposeFile = Join-Path $InstallDir "compose.yaml"
$EnvFile = Join-Path $InstallDir ".env"
$DataDir = Join-Path $InstallDir "vw-data"
$VaultURL = "http://localhost:8787"
$AdminURL = "http://localhost:8787/admin"

Write-Host ""
Write-Host "=== Instalando Vaultwarden ===" -ForegroundColor Cyan
Write-Host "Carpeta: $InstallDir"
Write-Host ""

# Verificar que Docker esté instalado
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker no está instalado o no está disponible en PowerShell."
}

# Verificar que Docker Desktop esté corriendo
docker info *> $null
if ($LASTEXITCODE -ne 0) {
    throw "Docker Desktop no está corriendo. Abre Docker Desktop y vuelve a ejecutar este script."
}

# Verificar Docker Compose
docker compose version *> $null
if ($LASTEXITCODE -ne 0) {
    throw "Docker Compose no está disponible."
}

# Proteger instalaciones existentes administradas desde otra carpeta
$ExistingContainer = docker ps -a `
    --filter "name=^/vaultwarden$" `
    --format "{{.Names}}" 2>$null |
    Select-Object -First 1

if ($ExistingContainer -eq "vaultwarden" -and -not (Test-Path $ComposeFile)) {
    throw "Ya existe un contenedor llamado 'vaultwarden'. No se modificó para proteger sus datos."
}

# Verificar puerto si es una instalación nueva
if (-not $ExistingContainer) {
    $PortInUse = Get-NetTCPConnection `
        -LocalPort 8787 `
        -State Listen `
        -ErrorAction SilentlyContinue

    if ($PortInUse) {
        throw "El puerto 8787 ya está siendo utilizado por otra aplicación."
    }
}

# Crear carpetas persistentes
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
New-Item -ItemType Directory -Path $DataDir -Force | Out-Null

# Crear o recuperar el token administrativo
if (-not (Test-Path $EnvFile)) {

    $RandomBytes = New-Object byte[] 32
    $RandomGenerator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $RandomGenerator.GetBytes($RandomBytes)
    $RandomGenerator.Dispose()

    $AdminToken = -join ($RandomBytes | ForEach-Object {
        $_.ToString("x2")
    })

    "VW_ADMIN_TOKEN=$AdminToken" |
        Set-Content -Path $EnvFile -Encoding ASCII
}
else {
    $TokenLine = Get-Content $EnvFile |
        Where-Object { $_ -match "^VW_ADMIN_TOKEN=" } |
        Select-Object -First 1

    if (-not $TokenLine) {
        throw "El archivo .env existe, pero no contiene VW_ADMIN_TOKEN."
    }

    $AdminToken = $TokenLine.Substring("VW_ADMIN_TOKEN=".Length)
}

# Crear Docker Compose
@'
services:
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    hostname: vaultwarden
    restart: unless-stopped

    ports:
      - "127.0.0.1:8787:80"

    environment:
      TZ: "America/Puerto_Rico"
      SIGNUPS_ALLOWED: "true"
      ADMIN_TOKEN: "${VW_ADMIN_TOKEN}"

    volumes:
      - "./vw-data:/data"
'@ | Set-Content -Path $ComposeFile -Encoding ASCII

# Descargar y levantar Vaultwarden
Push-Location $InstallDir

try {
    Write-Host "Descargando Vaultwarden..." -ForegroundColor Yellow
    docker compose pull

    if ($LASTEXITCODE -ne 0) {
        throw "No se pudo descargar la imagen de Vaultwarden."
    }

    Write-Host "Iniciando Vaultwarden..." -ForegroundColor Yellow
    docker compose up -d

    if ($LASTEXITCODE -ne 0) {
        throw "No se pudo iniciar Vaultwarden."
    }
}
finally {
    Pop-Location
}

Start-Sleep -Seconds 5

# Validar el contenedor
$ContainerStatus = docker inspect `
    --format "{{.State.Status}}" `
    vaultwarden 2>$null

if ($LASTEXITCODE -ne 0 -or $ContainerStatus -ne "running") {
    Write-Host ""
    Write-Host "=== Últimos registros ===" -ForegroundColor Red
    docker logs vaultwarden --tail 50
    throw "Vaultwarden no inició correctamente."
}

Write-Host ""
Write-Host "==============================================" -ForegroundColor Green
Write-Host " VAULTWARDEN INSTALADO CORRECTAMENTE" -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Vaultwarden:"
Write-Host $VaultURL -ForegroundColor Cyan
Write-Host ""
Write-Host "Panel administrativo:"
Write-Host $AdminURL -ForegroundColor Cyan
Write-Host ""
Write-Host "TOKEN ADMINISTRATIVO:" -ForegroundColor Yellow
Write-Host $AdminToken -ForegroundColor White
Write-Host ""
Write-Host "El token también está guardado en:"
Write-Host $EnvFile -ForegroundColor Gray
Write-Host ""
Write-Host "Datos persistentes:"
Write-Host $DataDir -ForegroundColor Gray
Write-Host ""
Write-Host "Crea ahora tu primera cuenta." -ForegroundColor Yellow
Write-Host "Después entra al panel /admin y desactiva nuevos registros."
Write-Host ""

Start-Process $VaultURL
