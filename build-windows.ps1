#Requires -Version 5.1
<#
.SYNOPSIS
    Portable Laravel Windows Distribution Builder v2.1.0
.DESCRIPTION
    Builds a fully self-contained, portable Laravel development environment for Windows x64.
    Downloads PHP TS, Xdebug, Composer, Node.js LTS and installs a complete Laravel
    application with SQLite, Vite, and full Xdebug support.
    Uses php artisan serve as the development HTTP server.
    No administrator privileges required.
.PARAMETER DistDir
    Root output directory (default: .\dist)
.PARAMETER SkipPackage
    Do not create the final portable-laravel-windows.zip archive
.PARAMETER IncludeDevTools
    Also install Laravel Telescope, Debugbar, Pest, Rector
.PARAMETER Force
    Remove and rebuild an existing distribution
.EXAMPLE
    .\build-windows.ps1
    .\build-windows.ps1 -IncludeDevTools
    .\build-windows.ps1 -SkipPackage -Force
#>
[CmdletBinding()]
param(
    [string]$DistDir     = ".\dist",
    [switch]$SkipPackage,
    [switch]$IncludeDevTools,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

# ============================================================
# PATHS
# ============================================================
$ROOT       = $PSScriptRoot
$BUILD_BASE = [System.IO.Path]::GetFullPath((Join-Path $ROOT $DistDir))
$DIST_NAME  = "portable-laravel-windows"
$DIST       = Join-Path $BUILD_BASE $DIST_NAME
$CACHE      = Join-Path $BUILD_BASE "_cache"
$ARCHIVE    = Join-Path $BUILD_BASE "$DIST_NAME.zip"

# Sub-directories inside the distribution
$PHP_DIR      = Join-Path $DIST "php"
$COMPOSER_DIR = Join-Path $DIST "composer"
$NODE_DIR     = Join-Path $DIST "node"
$APP_DIR      = Join-Path $DIST "app"
$DB_DIR       = Join-Path $DIST "database"
$TOOLS_DIR    = Join-Path $DIST "tools"
$TEMP_DIR     = Join-Path $DIST "temp"
$LOGS_DIR     = Join-Path $DIST "logs"

# ============================================================
# VERSION PINS  (update when new releases are available)
# ============================================================
$V = @{
    PHP_MINOR   = "8.4"
    PHP_VS      = "vs17"
    PHP_ARCH    = "x64"
    XDEBUG      = "3.4.2"
    NODE_SERIES = "v22"   # LTS major
    LARAVEL     = "^12.0"
    SERVER_HOST = "127.0.0.1"
    SERVER_PORT = "8080"
}

# ============================================================
# UI HELPERS
# ============================================================
function Write-Banner([string]$text) {
    $line = "=" * 62
    Write-Host ""
    Write-Host $line -ForegroundColor Cyan
    Write-Host ("  " + $text) -ForegroundColor White
    Write-Host $line -ForegroundColor Cyan
    Write-Host ""
}

function Write-Phase([string]$text) {
    Write-Host ""
    Write-Host ("--> " + $text) -ForegroundColor Yellow
}

function Write-Ok([string]$text) {
    Write-Host ("[OK] " + $text) -ForegroundColor Green
}

function Write-Info([string]$text) {
    Write-Host ("     " + $text) -ForegroundColor Gray
}

function Write-Warn([string]$text) {
    Write-Host ("[!!] " + $text) -ForegroundColor Magenta
}

# ============================================================
# NATIVE COMMAND HELPER
# PS 5.1: native exe stderr wrapped as ErrorRecord kills script when EAP=Stop.
# Use this helper to run external executables safely.
# ============================================================
function Invoke-Cmd {
    param([string]$Exe, [string[]]$ArgList, [switch]$Quiet, [switch]$PassThru)
    $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    $out = & $Exe @ArgList 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if (-not $Quiet) {
        $out | ForEach-Object { Write-Info ([string]$_) }
    }
    if ($PassThru) { return [pscustomobject]@{ Output = ($out | ForEach-Object { [string]$_ }) -join "`n"; ExitCode = $code } }
    return $code
}

# ============================================================
# NETWORK HELPERS
# ============================================================
function Invoke-Download([string]$uri, [string]$dest, [string]$label = "") {
    $file = Split-Path $dest -Leaf
    if (-not $label) { $label = $file }

    if (Test-Path $dest) {
        Write-Info "Cached: $label"
        return
    }
    Write-Info "Downloading $label ..."
    try {
        Invoke-WebRequest -Uri $uri -OutFile $dest -UseBasicParsing
        Write-Ok "Downloaded: $label"
    } catch {
        throw "Download failed for $uri`n$_"
    }
}

function Expand-ZipToDir([string]$zip, [string]$target, [switch]$Strip) {
    $tmp = "$target.tmp"
    if (Test-Path $tmp)    { Remove-Item $tmp -Recurse -Force }
    if (Test-Path $target) { Remove-Item $target -Recurse -Force }
    Write-Info "Extracting $(Split-Path $zip -Leaf) ..."
    Expand-Archive -Path $zip -DestinationPath $tmp -Force

    if ($Strip) {
        $inner = Get-ChildItem $tmp | Select-Object -First 1
        Move-Item $inner.FullName $target
        Remove-Item $tmp -Recurse -Force
    } else {
        Move-Item $tmp $target
    }
    Write-Ok "Extracted to $(Split-Path $target -Leaf)"
}

# ============================================================
# VERSION DETECTION
# ============================================================
function Get-LatestXdebugVersion {
    Write-Info "Querying Xdebug releases (PECL)..."
    try {
        [xml]$xml = (Invoke-WebRequest "https://pecl.php.net/rest/r/xdebug/allreleases.xml" -UseBasicParsing).Content
        $stable = $xml.a.r | Where-Object { $_.s -eq 'stable' } | Select-Object -First 1
        if ($stable) { return $stable.v }
    } catch { }
    Write-Warn "Could not query PECL; using pinned Xdebug $($V.XDEBUG)"
    return $V.XDEBUG
}

function Get-LatestNodeVersion {
    Write-Info "Querying Node.js LTS releases..."
    $index = Invoke-RestMethod "https://nodejs.org/dist/index.json"
    $lts = $index |
        Where-Object { $_.lts -and $_.version -match "^$($V.NODE_SERIES)\." } |
        Select-Object -First 1
    if (-not $lts) { throw "Could not detect Node.js $($V.NODE_SERIES) LTS" }
    return $lts.version.TrimStart("v")
}

# ============================================================
# PHASE 1 – WORKSPACE
# ============================================================
function Initialize-Workspace {
    Write-Phase "Initialising workspace"

    if ((Test-Path $DIST) -and $Force) {
        Write-Info "Removing existing distribution..."
        Remove-Item $DIST -Recurse -Force
    }

    foreach ($d in @($BUILD_BASE, $CACHE, $DIST, $PHP_DIR, $COMPOSER_DIR,
                      $NODE_DIR, $DB_DIR,
                      $TOOLS_DIR, $TEMP_DIR, $LOGS_DIR,
                      "$TEMP_DIR\sessions", "$TEMP_DIR\npm-cache",
                      "$TEMP_DIR\npm-global")) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }

    foreach ($d in @($LOGS_DIR, $TEMP_DIR, $DB_DIR)) {
        $gk = Join-Path $d ".gitkeep"
        if (-not (Test-Path $gk)) { "" | Set-Content $gk }
    }

    Write-Ok "Workspace ready: $DIST"
}

# ============================================================
# PHASE 2 – PHP
# ============================================================
function Install-PHP {
    Write-Phase "Installing PHP $($V.PHP_MINOR)"

    Write-Info "Querying PHP releases..."
    $releases = Invoke-RestMethod "https://windows.php.net/downloads/releases/releases.json"
    $entry    = $releases."$($V.PHP_MINOR)"
    if (-not $entry) { throw "PHP $($V.PHP_MINOR) not found in releases.json" }

    $phpVer  = $entry.version
    $Script:PHP_VERSION = $phpVer

    $zipPath = $entry.'ts-vs17-x64'.zip.path
    $sha256  = $entry.'ts-vs17-x64'.zip.sha256
    $url     = "https://windows.php.net/downloads/releases/$zipPath"
    $dest    = Join-Path $CACHE $zipPath

    Invoke-Download $url $dest "PHP $phpVer TS"

    $actualHash = (Get-FileHash $dest -Algorithm SHA256).Hash.ToLower()
    if ($actualHash -ne $sha256.ToLower()) {
        Remove-Item $dest -Force
        throw "SHA256 mismatch!`nExpected: $sha256`nActual:   $actualHash"
    }
    Write-Ok "Checksum OK (SHA256)"

    Expand-ZipToDir $dest $PHP_DIR
    New-Item -ItemType Directory -Force -Path "$TEMP_DIR\sessions" | Out-Null
    Write-Ok "PHP $phpVer installed to php\"
}

# ============================================================
# PHASE 2b – VC++ RUNTIME (for portability)
# ============================================================
function Install-VCRuntime {
    Write-Phase "Bundling VC++ 2022 runtime DLLs"

    $needed = @('vcruntime140.dll', 'vcruntime140_1.dll')
    $sys32  = [System.Environment]::SystemDirectory

    foreach ($dll in $needed) {
        $dest = Join-Path $PHP_DIR $dll
        if (Test-Path $dest) {
            Write-Info "Already present: $dll"
            continue
        }

        $src = Join-Path $sys32 $dll
        if (-not (Test-Path $src)) {
            Write-Warn "$dll not in System32 – downloading VC++ 2022 Redistributable..."
            $vcExe = Join-Path $CACHE "vc_redist.x64.exe"
            Invoke-Download "https://aka.ms/vs/17/release/vc_redist.x64.exe" $vcExe "VC++ 2022 Redistributable"
            Write-Info "Installing VC++ 2022 Redistributable silently..."
            $proc = Start-Process -FilePath $vcExe -ArgumentList "/install /quiet /norestart" -Wait -PassThru
            Write-Info "Installer exit code: $($proc.ExitCode)"
        }

        if (Test-Path $src) {
            Copy-Item $src $dest -Force
            Write-Ok "Bundled $dll"
        } else {
            Write-Warn "Could not bundle $dll – target machines must have VC++ 2022 installed"
        }
    }
}

# ============================================================
# PHASE 3 – XDEBUG
# ============================================================
function Find-XdebugVersion {
    # PECL may report a version whose DLL isn't yet published on xdebug.org.
    # Probe descending versions until a 200 HEAD response is found.
    $candidate = Get-LatestXdebugVersion
    $parts = $candidate -split '\.'
    $major = [int]$parts[0]; $minor = [int]$parts[1]; $patch = [int]$parts[2]

    # Build a list: candidate first, then walk patch down to 0, then minor down
    $probeList = [System.Collections.Generic.List[string]]::new()
    $probeList.Add($candidate)
    for ($p = $patch - 1; $p -ge 0; $p--) { $probeList.Add("$major.$minor.$p") }
    for ($mn = $minor - 1; $mn -ge 0; $mn--) {
        for ($p = 9; $p -ge 0; $p--) { $probeList.Add("$major.$mn.$p") }
    }

    foreach ($ver in $probeList) {
        $dll = "php_xdebug-$ver-$($V.PHP_MINOR)-$($V.PHP_VS)-x86_64.dll"
        $url = "https://xdebug.org/files/$dll"
        try {
            $r = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -ErrorAction Stop -TimeoutSec 10
            if ($r.StatusCode -eq 200) {
                Write-Ok "Xdebug $ver DLL found"
                return $ver
            }
        } catch { }
    }
    throw "Could not find a published Xdebug DLL for PHP $($V.PHP_MINOR) $($V.PHP_VS) x86_64"
}

function Install-Xdebug {
    Write-Phase "Installing Xdebug"
    $xdVer = Find-XdebugVersion
    $Script:XDEBUG_VERSION = $xdVer

    $dll    = "php_xdebug-$xdVer-$($V.PHP_MINOR)-$($V.PHP_VS)-x86_64.dll"
    $url    = "https://xdebug.org/files/$dll"
    $cached = Join-Path $CACHE $dll
    $extDir = Join-Path $PHP_DIR "ext"

    Invoke-Download $url $cached "Xdebug $xdVer"

    if (-not (Test-Path $extDir)) { New-Item -ItemType Directory $extDir -Force | Out-Null }
    Copy-Item $cached (Join-Path $extDir "php_xdebug.dll") -Force
    Write-Ok "Xdebug $xdVer installed to php\ext\php_xdebug.dll"
}

# ============================================================
# PHASE 4 – PHP.INI
# ============================================================
function Write-PhpIni {
    Write-Phase "Generating php.ini"

    $ini = @'
; ============================================================
; Portable Laravel Windows – php.ini
; Generated by build-windows.ps1
; DO NOT EDIT – runtime launcher rewrites this file from template.
; Edit php.ini.template instead.
; ============================================================

[PHP]
engine                  = On
short_open_tag          = Off
precision               = 14
output_buffering        = 4096
zlib.output_compression = Off
implicit_flush          = Off
serialize_precision     = -1
disable_functions       =
disable_classes         =
expose_php              = On
max_execution_time      = 0
max_input_time          = -1
memory_limit            = 2G

; Development error reporting
error_reporting         = E_ALL
display_errors          = On
display_startup_errors  = On
log_errors              = On
error_log               = __LOGS__/php_errors.log
html_errors             = On

post_max_size           = 512M
default_charset         = "UTF-8"
extension_dir           = "ext"
upload_max_filesize     = 512M
max_file_uploads        = 200
allow_url_fopen         = On
default_socket_timeout  = 60

[Date]
date.timezone = UTC

[Session]
session.save_handler    = files
session.save_path       = "__TEMP__/sessions"
session.use_strict_mode = 0
session.use_cookies     = 1
session.name            = PHPSESSID
session.gc_probability  = 1
session.gc_divisor      = 1000
session.gc_maxlifetime  = 1440

[Assertion]
zend.assertions  = 1
assert.active    = 1
assert.exception = 1

; ============================================================
; Extensions (bcmath/calendar/dom/iconv/Phar/xml* are built into PHP 8.4 core)
; ============================================================
extension=bz2
extension=curl
extension=exif
extension=fileinfo
extension=ftp
extension=gd
extension=gettext
extension=intl
extension=mbstring
extension=mysqli
extension=openssl
extension=pdo_mysql
extension=pdo_sqlite
extension=sockets
extension=sodium
extension=sqlite3
extension=zip

; ============================================================
; OPcache  (development config – validates timestamps)
; ============================================================
zend_extension=opcache

[opcache]
opcache.enable                 = 1
opcache.enable_cli             = 1
opcache.validate_timestamps    = 1
opcache.revalidate_freq        = 0
opcache.memory_consumption     = 256
opcache.interned_strings_buffer= 16
opcache.max_accelerated_files  = 20000
opcache.fast_shutdown          = 1

; ============================================================
; Xdebug
; ============================================================
zend_extension=php_xdebug.dll

[xdebug]
xdebug.mode                    = develop,debug,profile
xdebug.start_with_request      = yes
xdebug.client_host             = 127.0.0.1
xdebug.client_port             = 9003
xdebug.log_level               = 0
xdebug.idekey                  = VSCODE
xdebug.var_display_max_depth   = -1
xdebug.var_display_max_children= -1
xdebug.var_display_max_data    = -1
xdebug.output_dir              = __TEMP__
xdebug.profiler_output_dir     = __TEMP__
'@

    $templatePath = Join-Path $PHP_DIR "php.ini.template"
    $ini | Set-Content $templatePath -Encoding UTF8

    $initial = $ini `
        -replace '__LOGS__', ($LOGS_DIR -replace '\\','/')  `
        -replace '__TEMP__', ($TEMP_DIR -replace '\\','/')
    $initial | Set-Content (Join-Path $PHP_DIR "php.ini") -Encoding UTF8

    Write-Ok "php.ini and php.ini.template written"
}

# ============================================================
# PHASE 5 – COMPOSER
# ============================================================
function Install-Composer {
    Write-Phase "Installing Composer"

    $phar = Join-Path $COMPOSER_DIR "composer.phar"
    Invoke-Download "https://getcomposer.org/composer.phar" $phar "Composer (latest stable)"

    $r = Invoke-Cmd "$PHP_DIR\php.exe" @($phar, "--version") -Quiet -PassThru
    if ($r.Output -match 'Composer version ([\d.]+)') { $Script:COMPOSER_VERSION = $Matches[1] }
    else { $Script:COMPOSER_VERSION = "unknown" }

    Write-Ok "Composer installed ($($Script:COMPOSER_VERSION))"
}

# ============================================================
# PHASE 6 – NODE.JS
# ============================================================
function Install-NodeJS {
    Write-Phase "Installing Node.js LTS"

    $nodeVer = Get-LatestNodeVersion
    $Script:NODE_VERSION = $nodeVer

    $zip  = "node-v$nodeVer-win-x64.zip"
    $url  = "https://nodejs.org/dist/v$nodeVer/$zip"
    $dest = Join-Path $CACHE $zip

    Invoke-Download $url $dest "Node.js $nodeVer LTS"
    Expand-ZipToDir $dest $NODE_DIR -Strip

    Write-Ok "Node.js $nodeVer installed to node\"
}

# ============================================================
# PHASE 7 – LARAVEL
# ============================================================
function New-LaravelApp {
    Write-Phase "Creating Laravel application"

    if (Test-Path (Join-Path $APP_DIR "artisan")) {
        Write-Info "Laravel already installed – skipping"
        return
    }

    $php      = Join-Path $PHP_DIR "php.exe"
    $phpIni   = Join-Path $PHP_DIR "php.ini"
    $composer = Join-Path $COMPOSER_DIR "composer.phar"

    $env:XDEBUG_MODE      = "off"
    $env:COMPOSER_CACHE_DIR = $CACHE

    # Composer refuses to create-project into an existing directory; remove if empty.
    if ((Test-Path $APP_DIR) -and (Get-ChildItem $APP_DIR | Measure-Object).Count -eq 0) {
        Remove-Item $APP_DIR -Force
    }

    Write-Info "Running composer create-project (this takes a few minutes)..."
    $exitCode = Invoke-Cmd $php @("-c", $phpIni, "-d", "xdebug.mode=off", $composer,
        "create-project", "laravel/laravel", $APP_DIR, $V.LARAVEL,
        "--prefer-dist", "--no-interaction", "--no-progress")

    if ($exitCode -ne 0) { throw "composer create-project failed (exit $exitCode)" }

    # Remove any .git directories left by source-fallback clones
    Write-Info "Stripping .git directories from vendor..."
    Get-ChildItem (Join-Path $APP_DIR "vendor") -Recurse -Force -Directory -Filter ".git" -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }

    $env:XDEBUG_MODE        = $null
    $env:COMPOSER_CACHE_DIR = $null

    # Patch vite.config.js for Windows portability:
    #   - Bind to 127.0.0.1 (not 'localhost' which may fail DNS on some machines)
    #   - Explicit HMR host/port so the browser WebSocket connects correctly
    #   - usePolling for reliable file-change detection on Windows
    Write-Info "Patching vite.config.js for Windows HMR compatibility..."
    $viteCfg = Join-Path $APP_DIR "vite.config.js"
    $viteContent = @'
import { defineConfig } from 'vite';
import laravel from 'laravel-vite-plugin';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
    plugins: [
        laravel({
            input: ['resources/css/app.css', 'resources/js/app.js'],
            refresh: true,
        }),
        tailwindcss(),
    ],
    server: {
        // Bind explicitly to 127.0.0.1 — 'localhost' has DNS resolution
        // issues on some Windows machines (getaddrinfo failure).
        host: '127.0.0.1',
        port: 5173,

        // Only set the HMR host — DO NOT hardcode hmr.port.
        // If Vite falls back to a different port (due to a port conflict
        // from an orphaned node.exe), the HMR WebSocket must use that same
        // port.  Vite derives it automatically from server.port when
        // hmr.port is omitted.
        hmr: {
            host: '127.0.0.1',
        },

        watch: {
            // Use polling as a fallback for Windows file systems that do
            // not fire native FSEvents reliably (network drives, some NTFS
            // configurations, WSL mounts, etc.).
            usePolling: true,
            interval: 300,
        },

        // Allow requests coming from the artisan serve origin (:8080)
        cors: {
            origin: 'http://127.0.0.1:8080',
        },
    },
});
'@
    $viteContent | Set-Content $viteCfg -Encoding UTF8
    Write-Ok "vite.config.js patched"

    Write-Ok "Laravel created at app\"
}

# ============================================================
# PHASE 8 – CONFIGURE LARAVEL
# ============================================================
function Configure-Laravel {
    Write-Phase "Configuring Laravel (.env, SQLite, keys)"

    $php    = Join-Path $PHP_DIR "php.exe"
    $phpIni = Join-Path $PHP_DIR "php.ini"
    $artisan = Join-Path $APP_DIR "artisan"

    $r = Invoke-Cmd $php @("-c", $phpIni, "-d", "xdebug.mode=off", $artisan, "--version") -Quiet -PassThru
    if ($r.Output -match 'Laravel Framework ([\d.]+)') { $Script:LARAVEL_VERSION = $Matches[1] }
    else { $Script:LARAVEL_VERSION = "unknown" }

    $sqlite = Join-Path $DB_DIR "database.sqlite"
    if (-not (Test-Path $sqlite)) {
        [System.IO.File]::WriteAllBytes($sqlite, [byte[]]@())
        Write-Ok "Created database\database.sqlite"
    }

    $envFile = Join-Path $APP_DIR ".env"
    $env     = Get-Content $envFile

    $env = $env -replace '^APP_ENV=.*',      'APP_ENV=local'
    $env = $env -replace '^APP_DEBUG=.*',    'APP_DEBUG=true'
    $env = $env -replace '^APP_URL=.*',      "APP_URL=http://$($V.SERVER_HOST):$($V.SERVER_PORT)"
    $env = $env -replace '^DB_CONNECTION=.*','DB_CONNECTION=sqlite'

    $env = $env | Where-Object { $_ -notmatch '^DB_HOST=|^DB_PORT=|^DB_DATABASE=|^DB_USERNAME=|^DB_PASSWORD=' }
    $env += "DB_DATABASE=$($sqlite -replace '\\','/')"

    $env | Set-Content $envFile -Encoding UTF8

    Invoke-Cmd $php @("-c", $phpIni, "-d", "xdebug.mode=off", $artisan, "key:generate", "--force") -Quiet | Out-Null
    Write-Ok "App key generated"

    Write-Info "Running migrations..."
    $env:DB_DATABASE = $sqlite
    Invoke-Cmd $php @("-c", $phpIni, "-d", "xdebug.mode=off", $artisan, "migrate", "--force") | Out-Null
    $env:DB_DATABASE = $null

    Invoke-Cmd $php @("-c", $phpIni, "-d", "xdebug.mode=off", $artisan, "storage:link") -Quiet | Out-Null

    Write-Ok "Laravel configured"
}

# ============================================================
# PHASE 9 – NPM
# ============================================================
function Install-NpmDependencies {
    Write-Phase "Installing Node.js dependencies"

    $env:PATH               = "$NODE_DIR;$env:PATH"
    $env:npm_config_cache   = "$TEMP_DIR\npm-cache"
    $env:npm_config_prefix  = "$TEMP_DIR\npm-global"

    $prevLoc = Get-Location
    Set-Location $APP_DIR

    Write-Info "Running npm install..."
    $exitCode = Invoke-Cmd "$NODE_DIR\npm.cmd" @("install")
    if ($exitCode -ne 0) { Write-Warn "npm install finished with warnings" }

    Write-Info "Building Vite production assets..."
    $exitCode = Invoke-Cmd "$NODE_DIR\npm.cmd" @("run", "build")
    if ($exitCode -ne 0) { Write-Warn "npm run build finished with warnings" }

    Set-Location $prevLoc

    # Clear npm cache and global dirs — not needed at runtime
    Write-Info "Clearing npm build cache..."
    @("$TEMP_DIR\npm-cache", "$TEMP_DIR\npm-global") | ForEach-Object {
        if (Test-Path $_) { Remove-Item $_ -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $_ -Force | Out-Null
    }

    Write-Ok "Node modules installed and assets built"
}

# ============================================================
# PHASE 10 – OPTIONAL DEV TOOLS
# ============================================================
function Install-DevTools {
    Write-Phase "Installing optional dev tools"

    $php      = Join-Path $PHP_DIR "php.exe"
    $phpIni   = Join-Path $PHP_DIR "php.ini"
    $composer = Join-Path $COMPOSER_DIR "composer.phar"
    $sqlite   = Join-Path $DB_DIR "database.sqlite"

    function Run-Composer {
        param([string[]]$ComposerArgs)
        $allArgs = @("-c", $phpIni, "-d", "xdebug.mode=off", $composer) + $ComposerArgs +
                   @("--working-dir=$APP_DIR", "--no-interaction")
        $env:DB_DATABASE = $sqlite
        Invoke-Cmd $php $allArgs | Out-Null
        $env:DB_DATABASE = $null
    }

    function Run-Artisan {
        param([string[]]$ArtisanArgs)
        $env:DB_DATABASE = $sqlite
        Invoke-Cmd $php (@("-c", $phpIni, "-d", "xdebug.mode=off", (Join-Path $APP_DIR "artisan")) + $ArtisanArgs) | Out-Null
        $env:DB_DATABASE = $null
    }

    Write-Info "Installing Laravel Telescope..."
    Run-Composer "require", "laravel/telescope", "--dev"
    Run-Artisan  "telescope:install"
    Run-Artisan  "migrate", "--force"

    Write-Info "Installing Laravel Debugbar..."
    Run-Composer "require", "barryvdh/laravel-debugbar", "--dev"

    Write-Info "Installing Pest PHP..."
    Run-Composer "require", "pestphp/pest", "--dev", "--with-all-dependencies"
    Run-Artisan  "pest:install", "--no-interaction"

    Write-Info "Installing Rector..."
    Run-Composer "require", "rector/rector", "--dev"

    Write-Info "Installing PHP CS Fixer..."
    Run-Composer "require", "friendsofphp/php-cs-fixer", "--dev"

    Write-Ok "Dev tools installed"
}

# ============================================================
# PHASE 11 – LAUNCHER SCRIPTS
# ============================================================
function Write-LauncherScripts {
    Write-Phase "Generating launcher scripts"

    # ----------------------------------------------------------
    # _env.bat  (shared – sourced by all launchers)
    # ----------------------------------------------------------
    $envBat = @'
:: _env.bat – shared portable environment bootstrap
:: DIST_ROOT must be set by the caller before invoking this.

set "PHP_DIR=%DIST_ROOT%\php"
set "NODE_DIR=%DIST_ROOT%\node"
set "COMPOSER_DIR=%DIST_ROOT%\composer"
set "APP_DIR=%DIST_ROOT%\app"
set "DB_DIR=%DIST_ROOT%\database"
set "LOGS_DIR=%DIST_ROOT%\logs"
set "TEMP_DIR=%DIST_ROOT%\temp"

:: Ensure runtime directories
if not exist "%LOGS_DIR%"           mkdir "%LOGS_DIR%"
if not exist "%TEMP_DIR%"           mkdir "%TEMP_DIR%"
if not exist "%TEMP_DIR%\sessions"  mkdir "%TEMP_DIR%\sessions"
if not exist "%DB_DIR%"             mkdir "%DB_DIR%"
if not exist "%DB_DIR%\database.sqlite" type nul > "%DB_DIR%\database.sqlite"

:: Generate php.ini from template (resolves __LOGS__ and __TEMP__ at runtime)
powershell -NoProfile -NonInteractive -Command "(Get-Content '%PHP_DIR%\php.ini.template') -replace '__LOGS__', '%LOGS_DIR:\=/%' -replace '__TEMP__', '%TEMP_DIR:\=/%' | Set-Content '%PHP_DIR%\php.ini'"

:: Portable PATH (our binaries first)
set "PATH=%PHP_DIR%;%NODE_DIR%;%DIST_ROOT%;%PATH%"

:: PHP isolation
set "PHPRC=%PHP_DIR%"
set "PHP_INI_SCAN_DIR="

:: Node.js isolation
set "NODE_PATH=%NODE_DIR%\node_modules"
set "npm_config_cache=%TEMP_DIR%\npm-cache"
set "npm_config_prefix=%TEMP_DIR%\npm-global"
set "NPM_CONFIG_PREFIX=%TEMP_DIR%\npm-global"
set "npm_config_globalconfig=%TEMP_DIR%\npmrc"

:: Database (overrides .env; Laravel uses createImmutable so env var wins)
set "DB_DATABASE=%DB_DIR%\database.sqlite"
set "DB_CONNECTION=sqlite"

:: Server
set "LARAVEL_HOST=127.0.0.1"
set "LARAVEL_PORT=8080"
set "LARAVEL_URL=http://%LARAVEL_HOST%:%LARAVEL_PORT%"
'@
    $envBat | Set-Content (Join-Path $DIST "_env.bat") -Encoding ASCII

    # ----------------------------------------------------------
    # run.bat
    # ----------------------------------------------------------
    $runBat = @'
@echo off
setlocal EnableExtensions

:: ============================================================
:: Portable Laravel - run.bat
:: Starts Vite HMR + php artisan serve and opens the browser.
:: ============================================================

set "DIST_ROOT=%~dp0"
set "DIST_ROOT=%DIST_ROOT:~0,-1%"

call "%DIST_ROOT%\_env.bat"

echo.
echo  ===========================================================
echo   Portable Laravel Development Environment
echo  ===========================================================
echo.
echo   PHP:     %PHP_DIR%\php.exe
echo   Node:    %NODE_DIR%\node.exe
echo   App:     %APP_DIR%
echo   DB:      %DB_DATABASE%
echo   URL:     %LARAVEL_URL%
echo   Vite:    http://127.0.0.1:5173  (hot reload)
echo.
echo  ===========================================================
echo.

if not exist "%PHP_DIR%\php.exe" (
    echo [ERROR] PHP not found: %PHP_DIR%\php.exe
    pause & exit /b 1
)

:: -- Clean up any leftover processes from a previous run ------------------
for /f "tokens=5" %%a in ('netstat -aon 2^>nul ^| findstr ":5173 "') do (
    taskkill /PID %%a /F >nul 2>&1
)
for /f "tokens=5" %%a in ('netstat -aon 2^>nul ^| findstr ":8080 "') do (
    taskkill /PID %%a /F >nul 2>&1
)

:: -- Migrations -----------------------------------------------------------
echo Running migrations...
"%PHP_DIR%\php.exe" "%APP_DIR%\artisan" migrate --force 2>>"%LOGS_DIR%\artisan.log"

:: -- Write public/hot so Laravel serves assets from the Vite dev server --
echo http://127.0.0.1:5173> "%APP_DIR%\public\hot"

:: -- Start Vite in a separate window --------------------------------------
:: The window stays open so you can see HMR output and errors.
:: It cleans up public/hot automatically when it exits.
start "Vite HMR :5173" cmd /c ^
    "cd /d "%APP_DIR%" && "%NODE_DIR%\npm.cmd" run dev & del /f /q "%APP_DIR%\public\hot" 2>nul"

echo  Vite HMR starting in background window...
echo  Laravel starting on %LARAVEL_URL% ...
echo  Browser opens in a few seconds.
echo.
echo  Press Ctrl+C to stop Laravel.
echo  Run stop.bat to stop everything (Laravel + Vite).
echo.

:: -- Open browser after a short delay -------------------------------------
start "" /MIN cmd /c "timeout /t 4 /nobreak >nul & start "" %LARAVEL_URL%"

:: -- Start Laravel in the foreground (Ctrl+C to stop) --------------------
"%PHP_DIR%\php.exe" "%APP_DIR%\artisan" serve ^
    --host=%LARAVEL_HOST% ^
    --port=%LARAVEL_PORT% ^
    --no-reload ^
    2>&1

:: -- Cleanup when Laravel stops -------------------------------------------
echo.
echo Stopping Vite...
for /f "tokens=5" %%a in ('netstat -aon 2^>nul ^| findstr ":5173 "') do (
    taskkill /PID %%a /F >nul 2>&1
)
if exist "%APP_DIR%\public\hot" del /f /q "%APP_DIR%\public\hot"
echo All stopped.
pause
endlocal
'@
    $runBat | Set-Content (Join-Path $DIST "run.bat") -Encoding ASCII

    # ----------------------------------------------------------
    # shell.bat
    # ----------------------------------------------------------
    $shellBat = @'
@echo off
setlocal EnableExtensions

set "DIST_ROOT=%~dp0"
set "DIST_ROOT=%DIST_ROOT:~0,-1%"

call "%DIST_ROOT%\_env.bat"

echo.
echo  ===========================================================
echo   Portable Laravel – Development Shell
echo  ===========================================================
echo.
echo   Available: php  composer  npm  artisan  node
echo.
echo   artisan migrate
echo   artisan make:controller FooController --resource
echo   artisan route:list
echo   composer require package/name
echo   npm run dev
echo.
echo   Type 'exit' to leave.
echo  ===========================================================
echo.

doskey artisan="%PHP_DIR%\php.exe" "%APP_DIR%\artisan" $*
doskey composer="%PHP_DIR%\php.exe" "%COMPOSER_DIR%\composer.phar" $*
doskey npm="%NODE_DIR%\npm.cmd" $*

cmd /K "cd /d %APP_DIR%"
endlocal
'@
    $shellBat | Set-Content (Join-Path $DIST "shell.bat") -Encoding ASCII

    # ----------------------------------------------------------
    # artisan.bat
    # ----------------------------------------------------------
    @'
@echo off
setlocal
set "DIST_ROOT=%~dp0"
set "DIST_ROOT=%DIST_ROOT:~0,-1%"
call "%DIST_ROOT%\_env.bat"
"%PHP_DIR%\php.exe" "%APP_DIR%\artisan" %*
endlocal
'@ | Set-Content (Join-Path $DIST "artisan.bat") -Encoding ASCII

    # ----------------------------------------------------------
    # composer.bat
    # ----------------------------------------------------------
    @'
@echo off
setlocal
set "DIST_ROOT=%~dp0"
set "DIST_ROOT=%DIST_ROOT:~0,-1%"
call "%DIST_ROOT%\_env.bat"
"%PHP_DIR%\php.exe" "%COMPOSER_DIR%\composer.phar" %*
endlocal
'@ | Set-Content (Join-Path $DIST "composer.bat") -Encoding ASCII

    # ----------------------------------------------------------
    # npm.bat
    # ----------------------------------------------------------
    @'
@echo off
setlocal
set "DIST_ROOT=%~dp0"
set "DIST_ROOT=%DIST_ROOT:~0,-1%"
call "%DIST_ROOT%\_env.bat"
"%NODE_DIR%\npm.cmd" %*
endlocal
'@ | Set-Content (Join-Path $DIST "npm.bat") -Encoding ASCII

    # ----------------------------------------------------------
    # vite.bat
    # ----------------------------------------------------------
    @'
@echo off
setlocal
set "DIST_ROOT=%~dp0"
set "DIST_ROOT=%DIST_ROOT:~0,-1%"
call "%DIST_ROOT%\_env.bat"

echo.
echo  ===========================================================
echo   Vite HMR Dev Server
echo  ===========================================================
echo.
echo   Keep run.bat open in another window.
echo   Vite runs on http://127.0.0.1:5173
echo   Edit files in app\resources\ for live hot-reload.
echo.
echo   Press Ctrl+C to stop.
echo  ===========================================================
echo.

:: Kill any orphaned node.exe that may still be holding port 5173
:: from a previous Vite run that was not stopped cleanly.
:: This ensures Vite always binds to 5173 so the HMR WebSocket port
:: stays consistent (vite.config.js does not hardcode hmr.port).
for /f "tokens=5" %%a in ('netstat -aon 2^>nul ^| findstr ":5173 "') do (
    taskkill /PID %%a /F >nul 2>&1
)

:: Write public/hot so Laravel switches from pre-built assets to the Vite
:: dev server. Laravel only checks file existence + reads the URL.
echo http://127.0.0.1:5173> "%APP_DIR%\public\hot"
echo [Vite] Hot file written - Laravel is now using the dev server.

cd /d "%APP_DIR%"
"%NODE_DIR%\npm.cmd" run dev

:: When Vite stops (Ctrl+C or natural exit), clean up the hot file so
:: Laravel falls back to the pre-built assets in public/build/.
echo.
if exist "%APP_DIR%\public\hot" (
    del /f /q "%APP_DIR%\public\hot"
    echo [Vite] Hot file removed - Laravel reverted to production build.
)

endlocal
'@ | Set-Content (Join-Path $DIST "vite.bat") -Encoding ASCII

    # ----------------------------------------------------------
    # stop.bat
    # ----------------------------------------------------------
    @'
@echo off
echo Stopping Portable Laravel processes...
:: Find and kill the php.exe running artisan serve on port 8080
for /f "tokens=5" %%a in ('netstat -aon ^| findstr ":8080 "') do (
    taskkill /PID %%a /F 2>nul && echo Stopped process on port 8080.
)
taskkill /IM node.exe /F 2>nul && echo Node.js (Vite) stopped.
echo Done.
'@ | Set-Content (Join-Path $DIST "stop.bat") -Encoding ASCII

    Write-Ok "Launcher scripts written"
}

# ============================================================
# PHASE 12 – VSCODE CONFIGURATION
# ============================================================
function Write-VSCodeConfig {
    Write-Phase "Generating .vscode configuration"

    $vscodeDir = Join-Path $APP_DIR ".vscode"
    New-Item -ItemType Directory -Force -Path $vscodeDir | Out-Null

    @'
{
    "version": "0.2.0",
    "configurations": [
        {
            "name": "Listen for Xdebug",
            "type": "php",
            "request": "launch",
            "port": 9003,
            "hostname": "127.0.0.1",
            "pathMappings": {
                "${workspaceFolder}": "${workspaceFolder}"
            },
            "log": false,
            "xdebugSettings": {
                "max_data": -1,
                "max_depth": -1,
                "max_children": -1
            }
        },
        {
            "name": "Xdebug: Current Script",
            "type": "php",
            "request": "launch",
            "program": "${file}",
            "cwd": "${workspaceFolder}",
            "port": 9003,
            "runtimeExecutable": "${workspaceFolder}/../php/php.exe",
            "runtimeArgs": ["-c", "${workspaceFolder}/../php/php.ini"]
        }
    ]
}
'@ | Set-Content (Join-Path $vscodeDir "launch.json") -Encoding UTF8

    @'
{
    "recommendations": [
        "bmewburn.vscode-intelephense-client",
        "xdebug.php-debug",
        "onecentlin.laravel5-snippets",
        "ryannaddy.laravel-artisan",
        "amirmarmul.laravel-blade-vscode",
        "mikestead.dotenv",
        "esbenp.prettier-vscode",
        "dbaeumer.vscode-eslint",
        "editorconfig.editorconfig",
        "alexcvzz.vscode-sqlite",
        "mtxr.sqltools",
        "mtxr.sqltools-driver-sqlite",
        "bradlc.vscode-tailwindcss"
    ]
}
'@ | Set-Content (Join-Path $vscodeDir "extensions.json") -Encoding UTF8

    @'
{
    "php.validate.enable": false,
    "php.suggest.basic": false,
    "intelephense.environment.phpVersion": "8.4.0",
    "intelephense.files.maxSize": 5000000,
    "[php]": {
        "editor.formatOnSave": true,
        "editor.defaultFormatter": "bmewburn.vscode-intelephense-client"
    },
    "[blade]": { "editor.formatOnSave": false },
    "editor.tabSize": 4,
    "editor.insertSpaces": true,
    "files.associations": { "*.blade.php": "blade" },
    "emmet.includeLanguages": { "blade": "html" },
    "sqltools.connections": [
        {
            "name": "Laravel SQLite",
            "driver": "SQLite",
            "database": "${workspaceFolder}/../database/database.sqlite"
        }
    ]
}
'@ | Set-Content (Join-Path $vscodeDir "settings.json") -Encoding UTF8

    Write-Ok ".vscode configuration written"
}

# ============================================================
# PHASE 13 – README
# ============================================================
function Write-Readme {
    Write-Phase "Generating README.md"

    $phpVer      = $Script:PHP_VERSION
    $nodeVer     = $Script:NODE_VERSION
    $composerVer = $Script:COMPOSER_VERSION
    $laravelVer  = $Script:LARAVEL_VERSION
    $xdVer       = $Script:XDEBUG_VERSION
    $shost       = $V.SERVER_HOST
    $port        = $V.SERVER_PORT

    @"
# Portable Laravel – Windows Development Environment

> **Extract. Run. Code.** No installation, no admin rights, no system changes.

## Quick Start

```
Double-click  run.bat
```

Server starts on **http://${shost}:${port}** and the browser opens automatically.

The web server is **php artisan serve** – Laravel's built-in development server.

---

## Included Versions

| Component   | Version     |
|-------------|-------------|
| PHP         | $phpVer     |
| Laravel     | $laravelVer |
| Composer    | $composerVer|
| Node.js LTS | $nodeVer    |
| Xdebug      | $xdVer      |
| Database    | SQLite      |

---

## Directory Structure

``````
portable-laravel-windows/
├── php/               PHP $phpVer Thread Safe x64
│   ├── php.exe
│   ├── php.ini        (regenerated at each launch from template)
│   ├── php.ini.template
│   └── ext/
│       └── php_xdebug.dll
├── composer/
│   └── composer.phar
├── node/              Node.js $nodeVer LTS
│   ├── node.exe
│   └── npm.cmd
├── app/               Laravel $laravelVer application
│   ├── .env
│   ├── vendor/
│   ├── node_modules/
│   └── .vscode/
├── database/
│   └── database.sqlite
├── logs/
├── temp/
├── _env.bat           (shared env bootstrap)
├── run.bat            START HERE
├── shell.bat          Dev shell
├── artisan.bat        Artisan wrapper
├── composer.bat       Composer wrapper
├── npm.bat            npm wrapper
├── vite.bat           Vite dev server
└── stop.bat           Stop server
``````

---

## Web Server

This distribution uses **php artisan serve** – Laravel's built-in PHP development server.
It runs on http://${shost}:${port} and is perfect for local development.

To use a different port:
1. Edit ``_env.bat``
2. Change ``LARAVEL_PORT=8080`` to your desired port
3. Re-run ``run.bat``

---

## Launcher Scripts

### run.bat
Starts Laravel server, runs migrations, opens browser.

### shell.bat
Opens CMD with php, composer, npm, artisan in PATH:
``````cmd
artisan migrate
artisan make:controller UserController --resource
artisan route:list
artisan tinker
``````

### vite.bat
Starts Vite HMR server. Run alongside ``run.bat``:
``````
Window 1:  run.bat
Window 2:  vite.bat
``````

### artisan.bat
``````
artisan.bat migrate
artisan.bat make:model Post --migration --controller
``````

### composer.bat
``````
composer.bat require guzzlehttp/guzzle
composer.bat dump-autoload -o
``````

### npm.bat
``````
npm.bat install some-package
npm.bat run build
``````

### stop.bat
Kills the Laravel server and Vite process by port.

---

## Xdebug

Xdebug **$xdVer** is pre-configured and starts with every request.

| Setting | Value |
|---------|-------|
| Mode | develop, debug, profile |
| Port | 9003 |
| Client | 127.0.0.1 |
| IDE key | VSCODE |

### VSCode Setup
1. Install **PHP Debug** (xdebug.php-debug)
2. Open the ``app/`` folder in VSCode
3. Press **F5** → *Listen for Xdebug*
4. Set a breakpoint and open http://${shost}:${port}

### PHPStorm Setup
1. Settings → PHP → Debug → Xdebug – port **9003**
2. Settings → PHP → Servers – add ``127.0.0.1:${port}``
3. Click the phone icon → start listening
4. Set a breakpoint and refresh the browser

### Disable Xdebug (for performance)
``````cmd
set XDEBUG_MODE=off
run.bat
``````

---

## Database (SQLite)

File: ``database\database.sqlite``

``````
artisan.bat migrate
artisan.bat migrate:fresh --seed
artisan.bat tinker
``````

The SQLite Tools extension for VSCode provides a GUI browser:
``app/.vscode/settings.json`` has the connection pre-configured.

---

## Troubleshooting

### Port already in use
Edit ``_env.bat``, change ``LARAVEL_PORT=8080`` to another port.

### PHP extension not loading
``````
shell.bat
> php -m
``````
Check ``logs\php_errors.log`` for details.

### Xdebug not connecting
Verify port 9003 is not blocked by Windows Firewall.
Run ``php -d xdebug.mode=debug -m`` to confirm Xdebug loads.

### Composer out of memory
Edit ``php\php.ini.template``, increase ``memory_limit``.

---

## Updating Components

### Update Composer
Replace ``composer\composer.phar`` from https://getcomposer.org/composer.phar

### Update Node.js
Download ``node-vXX.X.X-win-x64.zip`` from https://nodejs.org and extract over ``node\``.

### Update PHP
Download PHP TS ZIP from https://windows.php.net/download, extract to ``php\``.
Download matching Xdebug DLL from https://xdebug.org, place in ``php\ext\php_xdebug.dll``.

---

*Built with build-windows.ps1 – Portable Laravel Distribution Builder*
"@ | Set-Content (Join-Path $DIST "README.md") -Encoding UTF8

    Write-Ok "README.md written"
}

# ============================================================
# PHASE 14 – MANIFEST
# ============================================================
function Write-Manifest {
    Write-Phase "Generating manifest.json"

    $manifest = [ordered]@{
        schema       = "portable-laravel/manifest/v1"
        platform     = "windows"
        architecture = "x86_64"
        build_date   = (Get-Date -Format "yyyy-MM-dd")
        build_tool   = "build-windows.ps1"
        server       = [ordered]@{ type = "php-artisan-serve"; host = $V.SERVER_HOST; port = [int]$V.SERVER_PORT }
        xdebug_port  = 9003
        ide_key      = "VSCODE"
        components   = [ordered]@{
            php      = [ordered]@{ version = $Script:PHP_VERSION; type = "thread-safe"; compiler = $V.PHP_VS }
            xdebug   = [ordered]@{ version = $V.XDEBUG }
            composer = [ordered]@{ version = $Script:COMPOSER_VERSION }
            nodejs   = [ordered]@{ version = $Script:NODE_VERSION; flavor = "lts" }
            laravel  = [ordered]@{ version = $Script:LARAVEL_VERSION }
        }
        database     = [ordered]@{ engine = "sqlite"; path = "database/database.sqlite" }
        extensions   = @("bcmath","bz2","calendar","curl","dom","exif","fileinfo",
                         "ftp","gd","gettext","iconv","intl","mbstring","mysqli",
                         "openssl","pdo_mysql","pdo_sqlite","Phar","sockets",
                         "sodium","sqlite3","xml","xmlreader","xmlwriter","zip",
                         "opcache","xdebug")
    }

    $manifest | ConvertTo-Json -Depth 10 |
        Set-Content (Join-Path $DIST "manifest.json") -Encoding UTF8
    Write-Ok "manifest.json written"
}

# ============================================================
# PHASE 15 – PACKAGE
# ============================================================
function Compress-Distribution {
    Write-Phase "Packaging distribution"

    if (Test-Path $ARCHIVE) { Remove-Item $ARCHIVE -Force }

    Write-Info "Creating $DIST_NAME.zip ..."
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $DIST, $ARCHIVE,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $true
    )
    $size = [math]::Round((Get-Item $ARCHIVE).Length / 1MB, 1)
    Write-Ok "Archive created: $ARCHIVE  ($size MB)"
}

# ============================================================
# MAIN
# ============================================================
Write-Banner "Portable Laravel Windows Distribution Builder v2.1.0"
Write-Info "Output:    $DIST"
Write-Info "Archive:   $ARCHIVE"
Write-Info "Dev tools: $IncludeDevTools"
Write-Info "Server:    php artisan serve"

$timer = [System.Diagnostics.Stopwatch]::StartNew()

Initialize-Workspace
Install-PHP
Install-VCRuntime
Install-Xdebug
Write-PhpIni
Install-Composer
Install-NodeJS
New-LaravelApp
Configure-Laravel
Install-NpmDependencies
if ($IncludeDevTools) { Install-DevTools }
Write-LauncherScripts
Write-VSCodeConfig
Write-Readme
Write-Manifest
if (-not $SkipPackage) { Compress-Distribution }

$timer.Stop()
$elapsed = $timer.Elapsed.ToString("mm\:ss")

Write-Banner "Build Complete in $elapsed"
Write-Info "Distribution: $DIST"
if (-not $SkipPackage) { Write-Info "Archive:      $ARCHIVE" }
Write-Host ""
Write-Host "  Run  $DIST\run.bat  to start developing." -ForegroundColor Green
Write-Host ""
