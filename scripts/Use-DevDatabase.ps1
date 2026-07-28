<#
.SYNOPSIS
Exporta ConnectionStrings__<Servicio>Database leyendo las credenciales de config/<servicio>-service.env.

.DESCRIPTION
Los .env son la unica fuente de verdad de las credenciales y solo Docker Compose los inyecta en los
contenedores. Este script hace el puente para trabajar desde el host: toma el usuario y la
contrasena del .env y compone la cadena contra localhost y el puerto publicado en
docker-compose.yml, porque los hostnames de contenedor (db-auth-service, db-peak-service) no
resuelven fuera de la red de Compose.

Necesario para 'dotnet ef database update'. Para 'dotnet ef migrations add' y
'dotnet ef migrations script' no hace falta: no abren conexion.

.EXAMPLE
. .\scripts\Use-DevDatabase.ps1 auth
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('auth', 'account', 'peak', 'ascent')]
    [string] $Service
)

$ErrorActionPreference = 'Stop'

if ($MyInvocation.InvocationName -ne '.') {
    Write-Warning "Usa dot-sourcing o la variable no persistira en esta sesion: . .\scripts\Use-DevDatabase.ps1 $Service"
}

function Read-PeakerEnvFile {
    param([string] $Path)

    $values = @{}

    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $trimmed = $line.Trim()

        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) { continue }

        $separator = $trimmed.IndexOf('=')
        if ($separator -lt 1) { continue }

        $values[$trimmed.Substring(0, $separator).Trim()] = $trimmed.Substring($separator + 1)
    }

    return $values
}

function Get-PeakerRequiredValue {
    param([hashtable] $Values, [string] $Name, [string] $EnvFile)

    if (-not $Values.ContainsKey($Name) -or [string]::IsNullOrWhiteSpace($Values[$Name])) {
        throw "Falta '$Name' en $EnvFile. Copia el .env.example correspondiente y completalo."
    }

    return $Values[$Name]
}

$catalog = @{
    'auth'    = @{ Key = 'AuthDatabase';    Engine = 'MySQL';      Port = 3307 }
    'account' = @{ Key = 'AccountDatabase'; Engine = 'MySQL';      Port = 3308 }
    'peak'    = @{ Key = 'PeakDatabase';    Engine = 'PostgreSQL'; Port = 5433 }
    'ascent'  = @{ Key = 'AscentDatabase';  Engine = 'PostgreSQL'; Port = 5434 }
}

$target = $catalog[$Service]
$envFile = Join-Path $PSScriptRoot "..\config\$Service-service.env"

if (-not (Test-Path -LiteralPath $envFile)) {
    throw "No existe $envFile. Copia config/$Service-service.env.example a config/$Service-service.env y completalo."
}

$values = Read-PeakerEnvFile -Path $envFile

if ($target.Engine -eq 'MySQL') {
    $database = Get-PeakerRequiredValue -Values $values -Name 'MYSQL_DATABASE' -EnvFile $envFile
    $user = Get-PeakerRequiredValue -Values $values -Name 'MYSQL_USER' -EnvFile $envFile
    $password = Get-PeakerRequiredValue -Values $values -Name 'MYSQL_PASSWORD' -EnvFile $envFile
    $connectionString = "server=localhost;port=$($target.Port);database=$database;user=$user;password=$password"
}
else {
    $database = Get-PeakerRequiredValue -Values $values -Name 'POSTGRES_DB' -EnvFile $envFile
    $user = Get-PeakerRequiredValue -Values $values -Name 'POSTGRES_USER' -EnvFile $envFile
    $password = Get-PeakerRequiredValue -Values $values -Name 'POSTGRES_PASSWORD' -EnvFile $envFile
    $connectionString = "Server=localhost;Port=$($target.Port);Database=$database;Username=$user;Password=$password"
}

Set-Item -Path "Env:ConnectionStrings__$($target.Key)" -Value $connectionString

Write-Host "ConnectionStrings__$($target.Key) -> localhost:$($target.Port)/$database (usuario: $user)"
