& {
    $ErrorActionPreference = "Continue"
    $ProgressPreference = "SilentlyContinue"

    $InstallFolder = Join-Path $env:USERPROFILE "Vaultwarden"
    $ThumbprintFile = Join-Path $InstallFolder "certificate-thumbprint.txt"
    $CertificateFile = Join-Path $InstallFolder "caddy-local-root.crt"

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Red
    Write-Host " Vaultwarden Complete Cleanup" -ForegroundColor Red
    Write-Host "============================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "This permanently deletes all Vaultwarden passwords and users." -ForegroundColor Yellow
    Write-Host ""

    $Confirmation = Read-Host "Type DELETE to continue"

    if ($Confirmation -cne "DELETE") {
        Write-Host "Cleanup cancelled." -ForegroundColor Yellow
        return
    }

    # Remove Tailscale Serve configuration.
    $TailscaleCommand = Get-Command tailscale -ErrorAction SilentlyContinue

    if ($null -ne $TailscaleCommand) {
        $TailscaleExe = $TailscaleCommand.Source
    }
    else {
        $TailscaleExe = Join-Path $env:ProgramFiles "Tailscale\tailscale.exe"
    }

    if (Test-Path $TailscaleExe) {
        Write-Host "Removing Tailscale Serve configuration..." -ForegroundColor Yellow
        & $TailscaleExe serve reset
    }

    # Remove the previous Caddy certificate.
    $CertificateThumbprints = @()

    if (Test-Path $ThumbprintFile) {
        $SavedThumbprint = (Get-Content $ThumbprintFile -Raw).Trim()

        if (-not [string]::IsNullOrWhiteSpace($SavedThumbprint)) {
            $CertificateThumbprints += $SavedThumbprint
        }
    }

    if (Test-Path $CertificateFile) {
        try {
            $OldCertificate =
                New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
                    $CertificateFile
                )

            if (-not [string]::IsNullOrWhiteSpace($OldCertificate.Thumbprint)) {
                $CertificateThumbprints += $OldCertificate.Thumbprint
            }
        }
        catch {
        }
    }

    foreach ($Thumbprint in ($CertificateThumbprints | Select-Object -Unique)) {
        $CertificatePath = "Cert:\CurrentUser\Root\$Thumbprint"

        if (Test-Path $CertificatePath) {
            Write-Host "Removing the old Caddy certificate..." -ForegroundColor Yellow

            Remove-Item `
                -LiteralPath $CertificatePath `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }

    if (Get-Command docker -ErrorAction SilentlyContinue) {
        $DockerCheck = @(& docker info 2>&1)

        if ($LASTEXITCODE -eq 0) {
            foreach ($ContainerName in @(
                "vaultwarden-caddy",
                "vaultwarden"
            )) {
                docker container rm `
                    --force `
                    $ContainerName 2>$null | Out-Null
            }

            foreach ($VolumeName in @(
                "vaultwarden-data",
                "vaultwarden-caddy-data",
                "vaultwarden-caddy-config",
                "vaultwarden-caddyfile"
            )) {
                docker volume rm `
                    --force `
                    $VolumeName 2>$null | Out-Null
            }

            foreach ($NetworkName in @(
                "vaultwarden-network",
                "vaultwarden_default"
            )) {
                docker network rm `
                    $NetworkName 2>$null | Out-Null
            }

            docker image rm `
                "vaultwarden/server:latest" 2>$null | Out-Null

            docker image rm `
                "caddy:2-alpine" 2>$null | Out-Null
        }
        else {
            Write-Host "Docker Desktop is not running; Docker resources were not removed." -ForegroundColor Red
        }
    }

    Set-Location $env:TEMP

    if (Test-Path $InstallFolder) {
        Remove-Item `
            -LiteralPath $InstallFolder `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Green
    Write-Host " Cleanup Completed" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Vaultwarden, Caddy and Tailscale Serve were removed."
    Write-Host "The Tailscale application remains installed."
    Write-Host ""
}
