& {
    $ErrorActionPreference = "Continue"
    $ProgressPreference = "SilentlyContinue"

    $ContainerName = "vaultwarden"
    $VolumeName    = "vaultwarden-data"
    $ImageName     = "vaultwarden/server:latest"
    $InstallFolder = Join-Path $env:USERPROFILE "Vaultwarden"
    $TokenFile     = Join-Path $InstallFolder "admin-token.txt"

    function Invoke-Docker {
        param(
            [Parameter(Mandatory = $true)]
            [string[]]$Arguments,
            [switch]$AllowFailure,
            [switch]$Quiet
        )

        $Output = @(& docker @Arguments 2>&1)
        $Code = $LASTEXITCODE
        $Lines = @($Output | ForEach-Object { $_.ToString() })

        if (-not $Quiet) {
            $Lines | ForEach-Object { Write-Host $_ }
        }

        if (($Code -ne 0) -and (-not $AllowFailure)) {
            throw "Docker failed with exit code ${Code}:`n$($Lines -join "`n")"
        }

        [PSCustomObject]@{
            ExitCode = $Code
            Output   = $Lines
        }
    }

    function Test-DockerResource {
        param(
            [string]$Type,
            [string]$Name
        )

        $Result = Invoke-Docker `
            -Arguments @($Type, "inspect", $Name) `
            -AllowFailure `
            -Quiet

        return ($Result.ExitCode -eq 0)
    }

    function New-AdminToken {
        $Bytes = New-Object byte[] 32
        $Generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()

        try {
            $Generator.GetBytes($Bytes)
        }
        finally {
            $Generator.Dispose()
        }

        return -join ($Bytes | ForEach-Object { $_.ToString("x2") })
    }

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " Vaultwarden Normal Docker Installation" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""

    try {
        if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
            throw "Docker was not found. Install and start Docker Desktop first."
        }

        $DockerCheck = Invoke-Docker `
            -Arguments @("info", "--format", "{{.OSType}}") `
            -AllowFailure `
            -Quiet

        if ($DockerCheck.ExitCode -ne 0) {
            throw "Docker Desktop is not running."
        }

        $DockerType = ($DockerCheck.Output -join "").Trim().ToLowerInvariant()

        if ($DockerType -ne "linux") {
            throw "Docker Desktop must be using Linux containers."
        }

        # Remove the previous Caddy containers.
        foreach ($OldContainer in @("vaultwarden-caddy", "vaultwarden")) {
            if (Test-DockerResource -Type "container" -Name $OldContainer) {
                Write-Host "Removing old container: $OldContainer" -ForegroundColor Yellow

                $null = Invoke-Docker `
                    -Arguments @("container", "rm", "--force", $OldContainer) `
                    -Quiet
            }
        }

        # Remove previous Caddy Docker resources.
        foreach ($OldVolume in @(
            "vaultwarden-caddy-data",
            "vaultwarden-caddy-config",
            "vaultwarden-caddyfile"
        )) {
            if (Test-DockerResource -Type "volume" -Name $OldVolume) {
                $null = Invoke-Docker `
                    -Arguments @("volume", "rm", "--force", $OldVolume) `
                    -AllowFailure `
                    -Quiet
            }
        }

        foreach ($OldNetwork in @(
            "vaultwarden-network",
            "vaultwarden_default"
        )) {
            if (Test-DockerResource -Type "network" -Name $OldNetwork) {
                $null = Invoke-Docker `
                    -Arguments @("network", "rm", $OldNetwork) `
                    -AllowFailure `
                    -Quiet
            }
        }

        # Remove the previous locally trusted Caddy certificate.
        $ThumbprintFile = Join-Path $InstallFolder "certificate-thumbprint.txt"
        $CertificateFile = Join-Path $InstallFolder "caddy-local-root.crt"
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

        New-Item `
            -ItemType Directory `
            -Path $InstallFolder `
            -Force | Out-Null

        foreach ($OldFile in @(
            $ThumbprintFile,
            $CertificateFile,
            (Join-Path $InstallFolder "Caddyfile")
        )) {
            Remove-Item `
                -LiteralPath $OldFile `
                -Force `
                -ErrorAction SilentlyContinue
        }

        # Reuse an existing admin token or generate a new one.
        if (Test-Path $TokenFile) {
            $AdminToken = (Get-Content $TokenFile -Raw).Trim()
        }
        else {
            $AdminToken = New-AdminToken
        }

        if ([string]::IsNullOrWhiteSpace($AdminToken)) {
            $AdminToken = New-AdminToken
        }

        Set-Content `
            -LiteralPath $TokenFile `
            -Value $AdminToken `
            -Encoding ASCII `
            -NoNewline

        Write-Host "Downloading Vaultwarden..." -ForegroundColor Yellow

        $null = Invoke-Docker `
            -Arguments @("image", "pull", "--quiet", $ImageName) `
            -Quiet

        if (-not (Test-DockerResource -Type "volume" -Name $VolumeName)) {
            $null = Invoke-Docker `
                -Arguments @("volume", "create", $VolumeName) `
                -Quiet
        }

        Write-Host "Starting Vaultwarden..." -ForegroundColor Yellow

        $null = Invoke-Docker `
            -Arguments @(
                "container", "run",
                "--detach",
                "--name", $ContainerName,
                "--restart", "unless-stopped",
                "--publish", "127.0.0.1:8080:80",
                "--volume", "${VolumeName}:/data",
                "--env", "DOMAIN=http://127.0.0.1:8080",
                "--env", "ADMIN_TOKEN=$AdminToken",
                "--env", "SIGNUPS_ALLOWED=true",
                "--env", "TZ=America/Puerto_Rico",
                $ImageName
            ) `
            -Quiet

        $Ready = $false

        for ($Attempt = 1; $Attempt -le 30; $Attempt++) {
            try {
                $Response = Invoke-WebRequest `
                    -Uri "http://127.0.0.1:8080/alive" `
                    -UseBasicParsing `
                    -TimeoutSec 3 `
                    -ErrorAction Stop

                if ($Response.StatusCode -eq 200) {
                    $Ready = $true
                    break
                }
            }
            catch {
                Start-Sleep -Seconds 2
            }
        }

        if (-not $Ready) {
            throw "The Vaultwarden container started but did not answer on port 8080."
        }

        Write-Host ""
        Write-Host "============================================" -ForegroundColor Green
        Write-Host " Vaultwarden Backend Is Ready" -ForegroundColor Green
        Write-Host "============================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "Local backend:" -ForegroundColor Cyan
        Write-Host "  http://127.0.0.1:8080"
        Write-Host ""
        Write-Host "Admin token:" -ForegroundColor Cyan
        Write-Host "  $AdminToken" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Now run the Tailscale Serve block below."
        Write-Host ""
    }
    catch {
        Write-Host ""
        Write-Host "Installation failed:" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        Write-Host ""
    }
}
