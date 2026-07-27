& {
    $ErrorActionPreference = "Continue"

    $ContainerName = "vaultwarden"
    $VolumeName    = "vaultwarden-data"
    $ImageName     = "vaultwarden/server:latest"
    $InstallFolder = Join-Path $env:USERPROFILE "Vaultwarden"
    $TokenFile     = Join-Path $InstallFolder "admin-token.txt"

    $TailscaleCommand = Get-Command tailscale -ErrorAction SilentlyContinue

    if ($null -ne $TailscaleCommand) {
        $TailscaleExe = $TailscaleCommand.Source
    }
    else {
        $TailscaleExe = Join-Path $env:ProgramFiles "Tailscale\tailscale.exe"
    }

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " Tailscale Serve Setup for Vaultwarden" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""

    try {
        if (-not (Test-Path $TailscaleExe)) {
            throw "Tailscale was not found. Install it and sign in first."
        }

        if (-not (Test-Path $TokenFile)) {
            throw "Vaultwarden's admin-token file was not found. Run the Vaultwarden installer first."
        }

        $AdminToken = (Get-Content $TokenFile -Raw).Trim()

        if ([string]::IsNullOrWhiteSpace($AdminToken)) {
            throw "The Vaultwarden admin token file is empty."
        }

        $StatusOutput = @(& $TailscaleExe status --json 2>&1)
        $StatusExitCode = $LASTEXITCODE

        if ($StatusExitCode -ne 0) {
            throw "Tailscale is not connected. Open Tailscale and sign in."
        }

        $TailscaleStatus =
            ($StatusOutput -join [Environment]::NewLine) |
            ConvertFrom-Json

        if ($TailscaleStatus.BackendState -ne "Running") {
            throw "Tailscale is installed but is not connected."
        }

        Write-Host "Enabling private HTTPS access..." -ForegroundColor Yellow

        $ServeOutput = @(
            & $TailscaleExe serve `
                --bg `
                --https=443 `
                http://127.0.0.1:8080 2>&1
        )

        $ServeExitCode = $LASTEXITCODE
        $ServeOutput | ForEach-Object { Write-Host $_ }

        if ($ServeExitCode -ne 0) {
            $ConsentUrl = (
                $ServeOutput |
                Select-String -Pattern "https://login\.tailscale\.com/\S+" -AllMatches |
                ForEach-Object { $_.Matches.Value } |
                Select-Object -First 1
            )

            if (-not [string]::IsNullOrWhiteSpace($ConsentUrl)) {
                Write-Host ""
                Write-Host "Tailscale requires one-time HTTPS approval." -ForegroundColor Yellow
                Start-Process $ConsentUrl
                Read-Host "Approve it in the browser, then press Enter here"

                $ServeOutput = @(
                    & $TailscaleExe serve `
                        --bg `
                        --https=443 `
                        http://127.0.0.1:8080 2>&1
                )

                $ServeExitCode = $LASTEXITCODE
                $ServeOutput | ForEach-Object { Write-Host $_ }
            }
        }

        if ($ServeExitCode -ne 0) {
            throw "Tailscale Serve could not be enabled."
        }

        # Read the final Tailscale HTTPS hostname.
        $StatusOutput = @(& $TailscaleExe status --json 2>&1)

        if ($LASTEXITCODE -ne 0) {
            throw "Could not retrieve the Tailscale DNS name."
        }

        $TailscaleStatus =
            ($StatusOutput -join [Environment]::NewLine) |
            ConvertFrom-Json

        $DnsName = ([string]$TailscaleStatus.Self.DNSName).Trim().TrimEnd(".")

        if ([string]::IsNullOrWhiteSpace($DnsName)) {
            throw "Tailscale did not provide a MagicDNS hostname."
        }

        $VaultUrl = "https://$DnsName"

        # Recreate Vaultwarden with the correct Tailscale HTTPS domain.
        docker container rm --force $ContainerName 2>$null | Out-Null

        $DockerOutput = @(
            docker container run `
                --detach `
                --name $ContainerName `
                --restart unless-stopped `
                --publish "127.0.0.1:8080:80" `
                --volume "${VolumeName}:/data" `
                --env "DOMAIN=$VaultUrl" `
                --env "ADMIN_TOKEN=$AdminToken" `
                --env "SIGNUPS_ALLOWED=true" `
                --env "TZ=America/Puerto_Rico" `
                $ImageName 2>&1
        )

        if ($LASTEXITCODE -ne 0) {
            throw "Vaultwarden could not be recreated:`n$($DockerOutput -join "`n")"
        }

        Start-Sleep -Seconds 5

        Write-Host ""
        Write-Host "============================================" -ForegroundColor Green
        Write-Host " Vaultwarden Is Ready Through Tailscale" -ForegroundColor Green
        Write-Host "============================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "Vaultwarden:" -ForegroundColor Cyan
        Write-Host "  $VaultUrl"
        Write-Host ""
        Write-Host "Registration:" -ForegroundColor Cyan
        Write-Host "  $VaultUrl/#/register"
        Write-Host ""
        Write-Host "Admin page:" -ForegroundColor Cyan
        Write-Host "  $VaultUrl/admin"
        Write-Host ""
        Write-Host "Admin token:" -ForegroundColor Cyan
        Write-Host "  $AdminToken" -ForegroundColor Yellow
        Write-Host ""

        & $TailscaleExe serve status

        Start-Process "$VaultUrl/#/register"
    }
    catch {
        Write-Host ""
        Write-Host "Tailscale setup failed:" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        Write-Host ""
    }
}
