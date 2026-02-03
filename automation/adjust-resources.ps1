# Script para ajustar recursos de los microservicios
# Se ejecuta desde deploy.bat

Get-ChildItem kustomize\base\*.yaml | ForEach-Object {
    $path = $_.FullName
    $lines = Get-Content $path
    $inRequests = $false
    $inLimits = $false
    $newLines = @()
    foreach ($line in $lines) {
        if ($line -match 'requests:') { $inRequests = $true; $inLimits = $false }
        if ($line -match 'limits:') { $inLimits = $true; $inRequests = $false }
        if ($inRequests -and $line -match 'cpu:') {
            $line = $line -replace 'cpu: [0-9]+m', 'cpu: 50m'
            $inRequests = $false
        }
        if ($inLimits -and $line -match 'cpu:') {
            $line = $line -replace 'cpu: [0-9]+m', 'cpu: 100m'
            $inLimits = $false
        }
        $newLines += $line
    }
    Set-Content $path $newLines
}
Write-Host '[OK] Recursos ajustados correctamente'
