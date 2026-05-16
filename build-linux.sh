#!/usr/bin/env bash
# =============================================================
# Portable Laravel Linux Distribution Builder v2.2.0
# =============================================================
# Creates a fully self-contained, portable Laravel development
# environment for Linux x86_64.
#
# Components:
#   - Static PHP (pre-built from dl.static-php.dev – no root needed)
#   - Composer PHAR
#   - Node.js LTS (portable binary)
#   - Laravel (installed with bundled tools)
#   - SQLite database
#   - OPcache pre-configured
#   - php artisan serve as the HTTP server
#
# No root/admin required for the BUILD or the DISTRIBUTION.
# BUILD machine requires: curl, tar, gzip, git
# (auto-detected; install instructions shown if missing).
#
# Usage:
#   chmod +x build-linux.sh
#   ./build-linux.sh
#   ./build-linux.sh --include-dev-tools
#   ./build-linux.sh --skip-package --force
# =============================================================

set -euo pipefail

# ---------------------------------------------------------------
# PARAMETERS
# ---------------------------------------------------------------
INCLUDE_DEV_TOOLS=false
SKIP_PACKAGE=false
FORCE=false
DIST_DIR="${DIST_DIR:-./dist}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --include-dev-tools) INCLUDE_DEV_TOOLS=true ;;
        --skip-package)      SKIP_PACKAGE=true ;;
        --force)             FORCE=true ;;
        --dist-dir)          DIST_DIR="$2"; shift ;;
        *) echo "Unknown option: $1" && exit 1 ;;
    esac
    shift
done

# ---------------------------------------------------------------
# PATHS
# ---------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_BASE="$(realpath -m "$SCRIPT_DIR/$DIST_DIR")"
DIST_NAME="portable-laravel-linux"
DIST="$BUILD_BASE/$DIST_NAME"
CACHE="$BUILD_BASE/_cache"
ARCHIVE="$BUILD_BASE/$DIST_NAME.tar.gz"

# Distribution sub-directories
PHP_DIR="$DIST/php"
PHP_BIN="$PHP_DIR/bin/php"
COMPOSER_DIR="$DIST/composer"
NODE_DIR="$DIST/node"
APP_DIR="$DIST/app"
DB_DIR="$DIST/database"
TOOLS_DIR="$DIST/tools"
TEMP_DIR="$DIST/temp"
LOGS_DIR="$DIST/logs"

# ---------------------------------------------------------------
# VERSION CONFIGURATION
# ---------------------------------------------------------------
PHP_MINOR="8.4"
NODE_SERIES="22"       # LTS major series
SERVER_HOST="127.0.0.1"
SERVER_PORT="8080"

# ---------------------------------------------------------------
# COLOUR OUTPUT
# ---------------------------------------------------------------
CYAN='\033[0;36m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
MAGENTA='\033[0;35m'; GRAY='\033[0;37m'; RESET='\033[0m'

banner() {
    echo -e "\n${CYAN}$( printf '=%.0s' {1..62} )${RESET}"
    echo -e "${CYAN}  $1${RESET}"
    echo -e "${CYAN}$( printf '=%.0s' {1..62} )${RESET}\n"
}
phase()  { echo -e "\n${YELLOW}--> $1${RESET}"; }
ok()     { echo -e "${GREEN}[OK]${RESET} $1"; }
info()   { echo -e "${GRAY}     $1${RESET}"; }
warn()   { echo -e "${MAGENTA}[!!]${RESET} $1"; }

# ---------------------------------------------------------------
# DOWNLOAD HELPER  (skips if cached)
# ---------------------------------------------------------------
download() {
    local url="$1" dest="$2" label="${3:-$(basename "$2")}"
    if [[ -f "$dest" ]]; then
        info "Cached: $label"
        return 0
    fi
    info "Downloading $label ..."
    if curl -fSL --progress-bar "$url" -o "$dest"; then
        ok "Downloaded: $label"
        return 0
    else
        return 1
    fi
}

# ---------------------------------------------------------------
# PHASE 0  –  BUILD PREREQUISITES
# ---------------------------------------------------------------
check_prerequisites() {
    phase "Checking build prerequisites"

    local missing=()
    for cmd in curl tar gzip git; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Missing required tools: ${missing[*]}"
        echo ""
        echo "Install with:"
        echo "  Ubuntu/Debian: sudo apt-get install -y ${missing[*]}"
        echo "  Fedora/RHEL:   sudo dnf install -y ${missing[*]}"
        echo "  Arch Linux:    sudo pacman -S --noconfirm ${missing[*]}"
        exit 1
    fi

    ok "All prerequisites satisfied"
}

# ---------------------------------------------------------------
# PHASE 1  –  WORKSPACE
# ---------------------------------------------------------------
init_workspace() {
    phase "Initialising workspace"

    if [[ -d "$DIST" && "$FORCE" == "true" ]]; then
        info "Removing existing distribution..."
        rm -rf "$DIST"
    fi

    for d in "$BUILD_BASE" "$CACHE" "$DIST" \
              "$PHP_DIR" "$PHP_DIR/bin" "$PHP_DIR/ext" \
              "$COMPOSER_DIR" "$NODE_DIR" \
              "$APP_DIR" "$DB_DIR" "$TOOLS_DIR" \
              "$TEMP_DIR" "$LOGS_DIR" \
              "$TEMP_DIR/sessions" "$TEMP_DIR/npm-cache" "$TEMP_DIR/npm-global"; do
        mkdir -p "$d"
    done

    for d in "$LOGS_DIR" "$TEMP_DIR" "$DB_DIR"; do
        touch "$d/.gitkeep"
    done

    ok "Workspace: $DIST"
}

# ---------------------------------------------------------------
# PHASE 2  –  PRE-BUILT STATIC PHP
# Downloads a fully-static, musl-linked PHP CLI binary from
# dl.static-php.dev – no compiler, no root, no system libraries.
# Works on any Linux x86_64 distribution.
# ---------------------------------------------------------------
build_php() {
    phase "Downloading pre-built static PHP $PHP_MINOR"

    if [[ -f "$PHP_BIN" ]]; then
        info "Static PHP already present – skipping download"
        PHP_VERSION="$("$PHP_BIN" --version 2>/dev/null | head -1 | grep -oP '\d+\.\d+\.\d+')"
        return
    fi

    local base_url="https://dl.static-php.dev/static-php-cli/common"
    local php_file=""

    info "Querying available PHP $PHP_MINOR builds..."

    # Attempt 1: JSON directory index
    local index
    index="$(curl -sfL "${base_url}/?format=json" 2>/dev/null)" || true

    if [[ -n "$index" ]]; then
        php_file="$(printf '%s' "$index" | \
            grep -oP 'php-'"$PHP_MINOR"'\.[0-9]+-cli-linux-x86_64\.tar\.gz' | \
            sort -V | tail -1)" || true
    fi

    # Attempt 2: probe known patch versions via HEAD (newest first)
    if [[ -z "$php_file" ]]; then
        warn "JSON index unavailable – probing latest PHP $PHP_MINOR release..."
        for patch in 30 29 28 27 26 25 24 23 22 21 20 19 18 17 16 15 14 13 12 11 10 9 8 7 6 5; do
            local candidate="php-${PHP_MINOR}.${patch}-cli-linux-x86_64.tar.gz"
            if curl -sfI "${base_url}/${candidate}" &>/dev/null; then
                php_file="$candidate"
                break
            fi
        done
    fi

    [[ -z "$php_file" ]] && { echo "ERROR: Cannot find a pre-built PHP $PHP_MINOR binary at $base_url"; exit 1; }
    info "Selecting: $php_file"

    local cached="$CACHE/${php_file}"
    download "${base_url}/${php_file}" "$cached" "PHP $PHP_MINOR CLI (static, musl)"

    info "Extracting PHP binary..."
    local extract_dir="$CACHE/php-extract"
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"
    tar -xzf "$cached" -C "$extract_dir"

    # Binary may be at root of archive or in a subdirectory
    local php_extracted
    php_extracted="$(find "$extract_dir" -maxdepth 3 -name 'php' -type f | head -1)"
    [[ -z "$php_extracted" ]] && { echo "ERROR: php binary not found inside $php_file"; exit 1; }

    cp "$php_extracted" "$PHP_BIN"
    chmod +x "$PHP_BIN"
    rm -rf "$extract_dir"

    PHP_VERSION="$("$PHP_BIN" --version 2>/dev/null | head -1 | grep -oP '\d+\.\d+\.\d+' | head -1)"
    ok "Static PHP $PHP_VERSION -> php/bin/php"
}

# ---------------------------------------------------------------
# PHASE 3  –  PHP.INI TEMPLATE
# ---------------------------------------------------------------
write_php_ini() {
    phase "Generating php.ini template"

    cat > "$PHP_DIR/php.ini.template" <<'PHP_INI'
; ============================================================
; Portable Laravel Linux – php.ini
; Generated by build-linux.sh
; DO NOT EDIT – runtime launcher regenerates this from template.
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
; OPcache  (validate timestamps – development mode)
; ============================================================
[opcache]
opcache.enable                  = 1
opcache.enable_cli              = 1
opcache.validate_timestamps     = 1
opcache.revalidate_freq         = 0
opcache.memory_consumption      = 256
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files   = 20000
opcache.fast_shutdown           = 1
PHP_INI

    # Generate an initial php.ini with build-time paths (overwritten on first launch)
    sed \
        -e "s|__LOGS__|$LOGS_DIR|g" \
        -e "s|__TEMP__|$TEMP_DIR|g" \
        "$PHP_DIR/php.ini.template" > "$PHP_DIR/php.ini"

    ok "php.ini and php.ini.template written"
}

# ---------------------------------------------------------------
# PHASE 4  –  COMPOSER
# ---------------------------------------------------------------
install_composer() {
    phase "Installing Composer"
    local phar="$COMPOSER_DIR/composer.phar"
    download "https://getcomposer.org/composer.phar" "$phar" "Composer (latest stable)"
    chmod +x "$phar"
    COMPOSER_VERSION="$("$PHP_BIN" "$phar" --version 2>/dev/null | \
        grep -oP 'Composer version \K[\d.]+')"
    ok "Composer $COMPOSER_VERSION installed"
}

# ---------------------------------------------------------------
# PHASE 5  –  NODE.JS LTS
# ---------------------------------------------------------------
install_nodejs() {
    phase "Installing Node.js $NODE_SERIES LTS"

    info "Querying Node.js LTS releases..."
    NODE_VERSION="$(curl -sfL "https://nodejs.org/dist/index.json" | \
        grep -oP '"version"\s*:\s*"\Kv'"$NODE_SERIES"'\.[^"]+(?=")' | head -1 | tr -d 'v')"
    [[ -z "$NODE_VERSION" ]] && { echo "Cannot detect Node.js $NODE_SERIES LTS"; exit 1; }

    local tarball="node-v${NODE_VERSION}-linux-x64.tar.gz"
    local url="https://nodejs.org/dist/v${NODE_VERSION}/${tarball}"
    local cached="$CACHE/$tarball"

    download "$url" "$cached" "Node.js $NODE_VERSION LTS"

    info "Extracting Node.js..."
    tar -xzf "$cached" -C "$NODE_DIR" --strip-components=1
    ok "Node.js $NODE_VERSION installed at node/"
}

# ---------------------------------------------------------------
# PHASE 6  –  CREATE LARAVEL APPLICATION
# ---------------------------------------------------------------
create_laravel() {
    phase "Creating Laravel application"

    if [[ -f "$APP_DIR/artisan" ]]; then
        info "Laravel already exists – skipping creation"
        return
    fi

    info "Running composer create-project (may take a few minutes)..."
    "$PHP_BIN" -c "$PHP_DIR/php.ini" \
        "$COMPOSER_DIR/composer.phar" create-project \
        "laravel/laravel" "$APP_DIR" \
        --prefer-dist --no-interaction --no-progress \
        2>&1 | grep -vE '^\s*-\s+Locking\s'

    [[ -f "$APP_DIR/artisan" ]] || { echo "ERROR: Laravel create-project failed"; exit 1; }

    # Patch vite.config.js: explicit host binding so HMR WebSocket works reliably
    info "Patching vite.config.js for HMR compatibility..."
    cat > "$APP_DIR/vite.config.js" <<'VITE_CFG'
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
        // Bind explicitly to 127.0.0.1 — avoids getaddrinfo failures on some systems
        host: '127.0.0.1',
        port: 5173,

        // Only set the HMR host — DO NOT hardcode hmr.port.
        // Vite derives it automatically from server.port when hmr.port is omitted,
        // so a port-conflict fallback keeps the WebSocket consistent.
        hmr: {
            host: '127.0.0.1',
        },

        // Allow requests from the artisan serve origin
        cors: {
            origin: 'http://127.0.0.1:8080',
        },
    },
});
VITE_CFG
    ok "vite.config.js patched"

    ok "Laravel created at app/"
}

# ---------------------------------------------------------------
# PHASE 7  –  CONFIGURE LARAVEL
# ---------------------------------------------------------------
configure_laravel() {
    phase "Configuring Laravel (.env, SQLite, app key)"

    local artisan="$APP_DIR/artisan"

    LARAVEL_VERSION="$("$PHP_BIN" "$artisan" --version 2>/dev/null | \
        grep -oP 'Laravel Framework \K[\d.]+')"

    # Create SQLite database
    [[ -f "$DB_DIR/database.sqlite" ]] || touch "$DB_DIR/database.sqlite"

    # Patch .env
    local envfile="$APP_DIR/.env"
    sed -i \
        -e 's/^APP_ENV=.*/APP_ENV=local/' \
        -e 's/^APP_DEBUG=.*/APP_DEBUG=true/' \
        -e "s|^APP_URL=.*|APP_URL=http://$SERVER_HOST:$SERVER_PORT|" \
        -e 's/^DB_CONNECTION=.*/DB_CONNECTION=sqlite/' \
        -e '/^DB_HOST=/d' \
        -e '/^DB_PORT=/d' \
        -e '/^DB_DATABASE=/d' \
        -e '/^DB_USERNAME=/d' \
        -e '/^DB_PASSWORD=/d' \
        "$envfile"

    echo "" >> "$envfile"
    echo "# Absolute path injected at runtime by _env.sh" >> "$envfile"
    echo "DB_DATABASE=$DB_DIR/database.sqlite" >> "$envfile"

    # Generate app key
    DB_DATABASE="$DB_DIR/database.sqlite" \
        "$PHP_BIN" -c "$PHP_DIR/php.ini" "$artisan" key:generate --force &>/dev/null
    ok "App key generated"

    # Run migrations
    info "Running migrations..."
    DB_DATABASE="$DB_DIR/database.sqlite" \
        "$PHP_BIN" -c "$PHP_DIR/php.ini" "$artisan" migrate --force 2>&1 | \
        grep -E 'Running|Migrated|Nothing' || true

    # Storage link
    "$PHP_BIN" -c "$PHP_DIR/php.ini" "$artisan" storage:link &>/dev/null || true

    ok "Laravel configured (v$LARAVEL_VERSION)"
}

# ---------------------------------------------------------------
# PHASE 8  –  NPM DEPENDENCIES
# ---------------------------------------------------------------
install_npm() {
    phase "Installing Node.js dependencies"

    export PATH="$NODE_DIR/bin:$PATH"
    export npm_config_cache="$TEMP_DIR/npm-cache"
    export npm_config_prefix="$TEMP_DIR/npm-global"

    info "Running npm install..."
    "$NODE_DIR/bin/npm" install --prefix "$APP_DIR" 2>&1 | tail -8

    info "Building Vite production assets..."
    "$NODE_DIR/bin/npm" --prefix "$APP_DIR" run build 2>&1 | tail -8

    # Clear npm cache and global dirs – not needed at runtime
    info "Clearing npm build cache..."
    rm -rf "$TEMP_DIR/npm-cache" "$TEMP_DIR/npm-global"
    mkdir -p "$TEMP_DIR/npm-cache" "$TEMP_DIR/npm-global"

    ok "Node modules installed and assets built"
}

# ---------------------------------------------------------------
# PHASE 9  –  OPTIONAL DEV TOOLS
# ---------------------------------------------------------------
install_dev_tools() {
    phase "Installing optional dev tools"

    local php="$PHP_BIN"
    local ini="$PHP_DIR/php.ini"
    local composer="$COMPOSER_DIR/composer.phar"
    local artisan="$APP_DIR/artisan"
    local db="$DB_DIR/database.sqlite"

    _composer() {
        DB_DATABASE="$db" \
            "$php" -c "$ini" "$composer" \
            --working-dir="$APP_DIR" --no-interaction "$@" 2>&1 | tail -5
    }
    _artisan() {
        DB_DATABASE="$db" \
            "$php" -c "$ini" "$artisan" "$@" 2>&1 | tail -3
    }

    info "Installing Laravel Telescope..."
    _composer require laravel/telescope --dev
    _artisan telescope:install
    _artisan migrate --force

    info "Installing Laravel Debugbar..."
    _composer require barryvdh/laravel-debugbar --dev

    info "Installing Pest PHP..."
    _composer require pestphp/pest --dev --with-all-dependencies
    _artisan pest:install --no-interaction

    info "Installing Rector..."
    _composer require rector/rector --dev

    info "Installing PHP CS Fixer..."
    _composer require friendsofphp/php-cs-fixer --dev

    ok "Dev tools installed"
}

# ---------------------------------------------------------------
# PHASE 10  –  LAUNCHER SCRIPTS
# ---------------------------------------------------------------
write_launchers() {
    phase "Generating launcher scripts"

    # ----------------------------------------------------------
    # _env.sh  –  shared environment bootstrap
    # ----------------------------------------------------------
    cat > "$DIST/_env.sh" <<'ENV_SH'
#!/usr/bin/env bash
# Shared portable environment bootstrap.
# Caller must set DIST_ROOT before sourcing.

PHP_DIR="$DIST_ROOT/php"
PHP_BIN="$PHP_DIR/bin/php"
NODE_DIR="$DIST_ROOT/node"
COMPOSER_DIR="$DIST_ROOT/composer"
APP_DIR="$DIST_ROOT/app"
DB_DIR="$DIST_ROOT/database"
LOGS_DIR="$DIST_ROOT/logs"
TEMP_DIR="$DIST_ROOT/temp"

# Ensure runtime directories exist
mkdir -p "$LOGS_DIR" "$TEMP_DIR" "$TEMP_DIR/sessions" "$DB_DIR" \
         "$TEMP_DIR/npm-cache" "$TEMP_DIR/npm-global"
[[ -f "$DB_DIR/database.sqlite" ]] || touch "$DB_DIR/database.sqlite"

# Regenerate php.ini from template (resolves __LOGS__, __TEMP__)
sed \
    -e "s|__LOGS__|$LOGS_DIR|g" \
    -e "s|__TEMP__|$TEMP_DIR|g" \
    "$PHP_DIR/php.ini.template" > "$PHP_DIR/php.ini"

# Portable PATH (our binaries prepended, never polluting system)
export PATH="$PHP_DIR/bin:$NODE_DIR/bin:$DIST_ROOT:$PATH"

# PHP isolation
export PHPRC="$PHP_DIR"
export PHP_INI_SCAN_DIR=""

# Node.js isolation
export NODE_PATH="$NODE_DIR/lib/node_modules"
export npm_config_cache="$TEMP_DIR/npm-cache"
export npm_config_prefix="$TEMP_DIR/npm-global"
export NPM_CONFIG_PREFIX="$TEMP_DIR/npm-global"
export npm_config_globalconfig="$TEMP_DIR/npmrc"

# Database – overrides .env; Laravel's createImmutable won't override env vars
export DB_DATABASE="$DB_DIR/database.sqlite"
export DB_CONNECTION="sqlite"

# Server (override via env before sourcing if you want a different port)
export LARAVEL_HOST="${LARAVEL_HOST:-127.0.0.1}"
export LARAVEL_PORT="${LARAVEL_PORT:-8080}"
export LARAVEL_URL="http://$LARAVEL_HOST:$LARAVEL_PORT"
ENV_SH
    chmod +x "$DIST/_env.sh"

    # ----------------------------------------------------------
    # run.sh
    # ----------------------------------------------------------
    cat > "$DIST/run.sh" <<'RUN_SH'
#!/usr/bin/env bash
# Portable Laravel – run.sh
# Starts Vite HMR + php artisan serve, runs migrations, opens browser.

set -euo pipefail
DIST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIST_ROOT/_env.sh"

echo ""
echo " ============================================================"
echo "  Portable Laravel Development Environment"
echo " ============================================================"
echo ""
echo "  PHP:      $PHP_BIN"
echo "  Node:     $NODE_DIR/bin/node"
echo "  App:      $APP_DIR"
echo "  DB:       $DB_DATABASE"
echo "  URL:      $LARAVEL_URL"
echo "  Vite:     http://127.0.0.1:5173  (hot reload)"
echo ""
echo "  Server:   php artisan serve"
echo " ============================================================"
echo ""

[[ -x "$PHP_BIN" ]] || { echo "[ERROR] PHP binary not executable: $PHP_BIN"; exit 1; }

# Clean up any leftover processes from a previous run
_kill_port() {
    local port="$1"
    if command -v fuser &>/dev/null; then
        fuser -k "${port}/tcp" 2>/dev/null || true
    elif command -v lsof &>/dev/null; then
        local pids
        pids="$(lsof -ti ":${port}" 2>/dev/null)" || true
        [[ -n "$pids" ]] && kill $pids 2>/dev/null || true
    fi
}
_kill_port 5173
_kill_port "$LARAVEL_PORT"

# Run database migrations
echo "Running migrations..."
"$PHP_BIN" "$APP_DIR/artisan" migrate --force 2>>"$LOGS_DIR/artisan.log" || \
    echo "[!!] Migration issues – see logs/artisan.log"

# Write public/hot so Laravel serves assets from the Vite dev server
echo "http://127.0.0.1:5173" > "$APP_DIR/public/hot"

# Start Vite in a background subshell; clean up hot file when it exits
(
    cd "$APP_DIR"
    "$NODE_DIR/bin/npm" run dev
    rm -f "$APP_DIR/public/hot"
) &
VITE_PID=$!
echo " Vite HMR starting in background (PID $VITE_PID)..."

echo " Laravel starting on $LARAVEL_URL ..."
echo " Browser opens in a few seconds."
echo ""
echo " Press Ctrl+C to stop."
echo ""

# Open browser after a short delay
if command -v xdg-open &>/dev/null; then
    (sleep 4 && xdg-open "$LARAVEL_URL" 2>/dev/null) &
elif command -v open &>/dev/null; then
    (sleep 4 && open "$LARAVEL_URL" 2>/dev/null) &
fi

# Trap to stop Vite and clean up when Laravel exits
_cleanup() {
    echo ""
    echo "Stopping Vite..."
    kill "$VITE_PID" 2>/dev/null || true
    rm -f "$APP_DIR/public/hot"
    echo "All stopped."
}
trap _cleanup EXIT INT TERM

"$PHP_BIN" "$APP_DIR/artisan" serve \
    --host="$LARAVEL_HOST" \
    --port="$LARAVEL_PORT" \
    2>&1 | tee -a "$LOGS_DIR/server.log"
RUN_SH
    chmod +x "$DIST/run.sh"

    # ----------------------------------------------------------
    # shell.sh
    # ----------------------------------------------------------
    cat > "$DIST/shell.sh" <<'SHELL_SH'
#!/usr/bin/env bash
# Portable Laravel – shell.sh
# Opens an interactive bash shell with all tools in PATH.

DIST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIST_ROOT/_env.sh"

echo ""
echo " ============================================================"
echo "  Portable Laravel – Development Shell"
echo " ============================================================"
echo ""
echo "  Available: php  composer  npm  artisan  node  npx"
echo ""
echo "  artisan migrate"
echo "  artisan make:controller UserController --resource"
echo "  artisan route:list"
echo "  artisan tinker"
echo "  composer require package/name"
echo "  npm run dev"
echo ""
echo "  Type 'exit' to leave."
echo " ============================================================"
echo ""

# Convenience aliases inside this shell
artisan()  { "$PHP_BIN" "$APP_DIR/artisan" "$@"; }
composer() { "$PHP_BIN" "$COMPOSER_DIR/composer.phar" "$@"; }
export -f artisan composer

cd "$APP_DIR"
exec bash --norc --noprofile -i
SHELL_SH
    chmod +x "$DIST/shell.sh"

    # ----------------------------------------------------------
    # artisan.sh
    # ----------------------------------------------------------
    cat > "$DIST/artisan.sh" <<'ARTISAN_SH'
#!/usr/bin/env bash
DIST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIST_ROOT/_env.sh"
exec "$PHP_BIN" "$APP_DIR/artisan" "$@"
ARTISAN_SH
    chmod +x "$DIST/artisan.sh"

    # ----------------------------------------------------------
    # composer.sh
    # ----------------------------------------------------------
    cat > "$DIST/composer.sh" <<'COMP_SH'
#!/usr/bin/env bash
DIST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIST_ROOT/_env.sh"
exec "$PHP_BIN" "$COMPOSER_DIR/composer.phar" "$@"
COMP_SH
    chmod +x "$DIST/composer.sh"

    # ----------------------------------------------------------
    # npm.sh
    # ----------------------------------------------------------
    cat > "$DIST/npm.sh" <<'NPM_SH'
#!/usr/bin/env bash
DIST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIST_ROOT/_env.sh"
exec "$NODE_DIR/bin/npm" "$@"
NPM_SH
    chmod +x "$DIST/npm.sh"

    # ----------------------------------------------------------
    # vite.sh
    # ----------------------------------------------------------
    cat > "$DIST/vite.sh" <<'VITE_SH'
#!/usr/bin/env bash
# Portable Laravel – vite.sh
# Starts the Vite HMR dev server standalone. Run alongside run.sh.

DIST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIST_ROOT/_env.sh"

echo ""
echo " ============================================================"
echo "  Vite HMR Dev Server"
echo " ============================================================"
echo ""
echo "  Keep run.sh open in another terminal."
echo "  Vite runs on http://127.0.0.1:5173"
echo "  Edit files in app/resources/ for live hot-reload."
echo ""
echo "  Press Ctrl+C to stop."
echo " ============================================================"
echo ""

# Kill any orphaned process still holding port 5173 from a previous run.
# Ensures Vite always binds to 5173 so the HMR WebSocket port stays consistent.
if command -v fuser &>/dev/null; then
    fuser -k 5173/tcp 2>/dev/null || true
elif command -v lsof &>/dev/null; then
    pids="$(lsof -ti :5173 2>/dev/null)" || true
    [[ -n "$pids" ]] && kill $pids 2>/dev/null || true
fi

# Write public/hot so Laravel switches from pre-built assets to the Vite dev server
echo "http://127.0.0.1:5173" > "$APP_DIR/public/hot"
echo "[Vite] Hot file written – Laravel is now using the dev server."

cd "$APP_DIR"
"$NODE_DIR/bin/npm" run dev

# When Vite stops (Ctrl+C or natural exit), remove hot so Laravel
# falls back to the pre-built assets in public/build/
echo ""
if [[ -f "$APP_DIR/public/hot" ]]; then
    rm -f "$APP_DIR/public/hot"
    echo "[Vite] Hot file removed – Laravel reverted to production build."
fi
VITE_SH
    chmod +x "$DIST/vite.sh"

    # ----------------------------------------------------------
    # stop.sh
    # ----------------------------------------------------------
    cat > "$DIST/stop.sh" <<'STOP_SH'
#!/usr/bin/env bash
# Portable Laravel – stop.sh
# Kills the artisan serve (port 8080) and Vite (port 5173) processes.

echo "Stopping Portable Laravel processes..."

DIST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIST_ROOT/_env.sh" 2>/dev/null || LARAVEL_PORT=8080

_kill_port() {
    local port="$1"
    if command -v fuser &>/dev/null; then
        fuser -k "${port}/tcp" 2>/dev/null && echo "Stopped process on port ${port}." || true
    elif command -v lsof &>/dev/null; then
        local pids
        pids="$(lsof -ti ":${port}" 2>/dev/null)" || true
        [[ -n "$pids" ]] && kill $pids 2>/dev/null && echo "Stopped process on port ${port}." || true
    fi
}

_kill_port "$LARAVEL_PORT"
_kill_port 5173

pkill -f "npm run dev" 2>/dev/null && echo "Vite stopped." || true
if [[ -f "$APP_DIR/public/hot" ]]; then
    rm -f "$APP_DIR/public/hot"
    echo "Hot file removed."
fi
echo "Done."
STOP_SH
    chmod +x "$DIST/stop.sh"

    ok "Launcher scripts written (+x set)"
}

# ---------------------------------------------------------------
# PHASE 11  –  VSCODE CONFIG
# ---------------------------------------------------------------
write_vscode() {
    phase "Generating .vscode configuration"

    local vscode_dir="$APP_DIR/.vscode"
    mkdir -p "$vscode_dir"

    cat > "$vscode_dir/launch.json" <<'LAUNCH'
{
    "version": "0.2.0",
    "configurations": [
        {
            "name": "PHP: Built-in Server",
            "type": "node",
            "request": "launch",
            "runtimeExecutable": "${workspaceFolder}/../php/bin/php",
            "runtimeArgs": ["-S", "127.0.0.1:8080", "-t", "public"],
            "cwd": "${workspaceFolder}",
            "console": "integratedTerminal"
        }
    ]
}
LAUNCH

    cat > "$vscode_dir/extensions.json" <<'EXT'
{
    "recommendations": [
        "bmewburn.vscode-intelephense-client",
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
EXT

    cat > "$vscode_dir/settings.json" <<'SETTINGS'
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
SETTINGS

    ok ".vscode configuration written"
}

# ---------------------------------------------------------------
# PHASE 12  –  README
# ---------------------------------------------------------------
write_readme() {
    phase "Generating README.md"

    cat > "$DIST/README.md" <<README
# Portable Laravel – Linux Development Environment

> **Extract. Run. Code.** No installation, no root, no system changes.

## Quick Start

\`\`\`bash
tar -xzf portable-laravel-linux.tar.gz
cd portable-laravel-linux
./run.sh
\`\`\`

Server starts on **http://$SERVER_HOST:$SERVER_PORT** using **php artisan serve**.
The browser opens automatically.

---

## Included Versions

| Component   | Version              |
|-------------|----------------------|
| PHP         | $PHP_VERSION         |
| Laravel     | $LARAVEL_VERSION     |
| Composer    | $COMPOSER_VERSION    |
| Node.js LTS | $NODE_VERSION        |
| Database    | SQLite               |
| Server      | php artisan serve    |

---

## Directory Structure

\`\`\`
portable-laravel-linux/
├── php/               Static PHP $PHP_VERSION
│   ├── bin/php        (statically compiled – no system libs required)
│   ├── php.ini        (regenerated at each launch)
│   └── php.ini.template
├── composer/
│   └── composer.phar
├── node/              Node.js $NODE_VERSION LTS
│   ├── bin/node
│   ├── bin/npm
│   └── bin/npx
├── app/               Laravel $LARAVEL_VERSION
│   ├── .env
│   ├── vendor/
│   ├── node_modules/
│   └── .vscode/
├── database/
│   └── database.sqlite
├── logs/
├── temp/
├── _env.sh            (shared env bootstrap – sourced by all launchers)
├── run.sh             START HERE
├── shell.sh           Dev shell
├── artisan.sh         Artisan wrapper
├── composer.sh        Composer wrapper
├── npm.sh             npm wrapper
├── vite.sh            Vite dev server
└── stop.sh            Stop all processes
\`\`\`

---

## Web Server

This distribution uses **php artisan serve** – Laravel's built-in development HTTP server.
It uses the bundled static PHP binary and is perfectly suited for local development.

To use a different port:
\`\`\`bash
LARAVEL_PORT=9090 ./run.sh
\`\`\`

---

## Launcher Scripts

### run.sh
Starts the server, runs migrations, opens browser.

### shell.sh
Opens an interactive bash session with all tools in PATH:
\`\`\`bash
./shell.sh
# inside the shell:
artisan migrate
composer require package/name
npm run dev
\`\`\`

### vite.sh
Starts Vite HMR (hot module replacement). Run alongside \`run.sh\`:
\`\`\`bash
# Terminal 1
./run.sh
# Terminal 2
./vite.sh
\`\`\`

### artisan.sh
\`\`\`bash
./artisan.sh migrate
./artisan.sh make:controller UserController --resource
./artisan.sh route:list
./artisan.sh tinker
\`\`\`

### composer.sh
\`\`\`bash
./composer.sh require guzzlehttp/guzzle
./composer.sh dump-autoload -o
\`\`\`

### npm.sh
\`\`\`bash
./npm.sh install some-package
./npm.sh run build
\`\`\`

### stop.sh
Kills the artisan serve process and Vite.

---

## Database (SQLite)

Database file: \`database/database.sqlite\`

\`\`\`bash
./artisan.sh migrate
./artisan.sh migrate:fresh --seed
./artisan.sh tinker

# Direct SQLite access (if sqlite3 is installed on system)
sqlite3 database/database.sqlite
\`\`\`

The \`.vscode/settings.json\` has a pre-configured SQLTools connection.

---

## Environment Variables

Key \`app/.env\` settings:

| Variable | Value |
|----------|-------|
| APP_ENV | local |
| APP_DEBUG | true |
| APP_URL | http://$SERVER_HOST:$SERVER_PORT |
| DB_CONNECTION | sqlite |
| DB_DATABASE | (absolute path – set by \`_env.sh\` at runtime) |

The launcher always overrides \`DB_DATABASE\` with the current absolute path.
Move the distribution anywhere and it still works.

---

## Troubleshooting

### Port 8080 already in use
\`\`\`bash
LARAVEL_PORT=9090 ./run.sh
\`\`\`

### PHP binary won't execute
\`\`\`bash
chmod +x php/bin/php
# Verify it is a static binary
file php/bin/php
ldd php/bin/php    # should say "statically linked"
\`\`\`

### npm / Vite issues
\`\`\`bash
rm -rf app/node_modules
./npm.sh install --prefix app
\`\`\`

### Composer out of memory
Edit \`php/php.ini.template\`, increase \`memory_limit\`.

---

## Updating

### Update Composer
\`\`\`bash
curl -o composer/composer.phar https://getcomposer.org/composer.phar
\`\`\`

### Update Node.js
Download \`node-vXX.X.X-linux-x64.tar.gz\` from https://nodejs.org and extract over \`node/\`.

### Rebuild PHP
Edit \`PHP_MINOR\` in \`build-linux.sh\` and re-run it with \`--force\`.

---

## PHP Extensions

Bundled in \`php/bin/php\` (pre-built static binary from dl.static-php.dev):

bcmath, bz2, calendar, ctype, curl, dom, exif, fileinfo, filter, ftp, gd, gmp,
iconv, mbstring, mysqlnd, openssl, pcntl, pdo, pdo_mysql, pdo_sqlite, pgsql,
pdo_pgsql, phar, posix, session, redis, simplexml, soap, sockets, sqlite3,
tokenizer, xml, xmlreader, xmlwriter, zip, zlib, **OPcache**

---

*Built with build-linux.sh – Portable Laravel Distribution Builder*
README

    ok "README.md written"
}

# ---------------------------------------------------------------
# PHASE 13  –  MANIFEST
# ---------------------------------------------------------------
write_manifest() {
    phase "Generating manifest.json"

    cat > "$DIST/manifest.json" <<MANIFEST
{
    "schema":       "portable-laravel/manifest/v1",
    "platform":     "linux",
    "architecture": "x86_64",
    "build_date":   "$(date -u +%Y-%m-%d)",
    "build_tool":   "build-linux.sh",
    "server":       { "type": "php-artisan-serve", "host": "$SERVER_HOST", "port": $SERVER_PORT },
    "components": {
        "php":      { "version": "$PHP_VERSION", "type": "static-cli", "source": "dl.static-php.dev" },
        "composer": { "version": "$COMPOSER_VERSION" },
        "nodejs":   { "version": "$NODE_VERSION", "flavor": "lts" },
        "laravel":  { "version": "$LARAVEL_VERSION" }
    },
    "database": { "engine": "sqlite", "path": "database/database.sqlite" },
    "extensions": [
        "bcmath","bz2","calendar","ctype","curl","dom","exif","fileinfo",
        "filter","ftp","gd","gmp","iconv","mbstring","mysqlnd",
        "openssl","pcntl","pdo","pdo_mysql","pdo_sqlite","pgsql","pdo_pgsql",
        "phar","posix","session","redis","simplexml","soap","sockets",
        "sqlite3","tokenizer","xml","xmlreader","xmlwriter","zip","zlib","opcache"
    ]
}
MANIFEST

    ok "manifest.json written"
}

# ---------------------------------------------------------------
# PHASE 14  –  PACKAGE
# ---------------------------------------------------------------
package_dist() {
    phase "Packaging distribution"

    [[ -f "$ARCHIVE" ]] && rm -f "$ARCHIVE"
    info "Creating $DIST_NAME.tar.gz ..."
    tar -czf "$ARCHIVE" -C "$BUILD_BASE" "$DIST_NAME"

    local size
    size="$(du -sh "$ARCHIVE" | cut -f1)"
    ok "Archive: $ARCHIVE  ($size)"
}

# ---------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------
banner "Portable Laravel Linux Distribution Builder v2.2.0"
info "Output:    $DIST"
info "Archive:   $ARCHIVE"
info "Dev tools: $INCLUDE_DEV_TOOLS"
info "Server:    php artisan serve"

START_TS="$(date +%s)"

check_prerequisites
init_workspace
build_php
write_php_ini
install_composer
install_nodejs
create_laravel
configure_laravel
install_npm
[[ "$INCLUDE_DEV_TOOLS" == "true" ]] && install_dev_tools
write_launchers
write_vscode
write_readme
write_manifest
[[ "$SKIP_PACKAGE" != "true" ]] && package_dist

ELAPSED=$(( $(date +%s) - START_TS ))
banner "Build Complete in $(( ELAPSED/60 ))m $(( ELAPSED%60 ))s"
info "Distribution: $DIST"
[[ "$SKIP_PACKAGE" != "true" ]] && info "Archive: $ARCHIVE"
echo ""
echo -e "${GREEN}  Run  $DIST/run.sh  to start developing.${RESET}"
echo ""
