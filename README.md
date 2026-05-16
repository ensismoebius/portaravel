# Portable Laravel

<div align="center">
  <img src="mascot.svg" width="180" alt="Portaravel mascot – a cheerful red door on wheels holding a terminal"/>
</div>

> **Extract. Run. Code.** No installation, no admin rights, no system changes.

Fully self-contained Laravel development environment for **Linux** and **Windows**.
No compilers, no root, no system packages — just `curl` and `tar`.

> **Portaravel** = *Porta* (🇧🇷 door) + *Portable* + *Laravel*

---

### One-liner install & run

**Linux:**
```bash
curl -fsSL https://github.com/ensismoebius/portaravel/releases/latest/download/portable-laravel-linux.tar.gz | tar -xz && cd portable-laravel-linux && ./run.sh
```

**Windows (PowerShell):**
```powershell
irm https://github.com/ensismoebius/portaravel/releases/latest/download/portable-laravel-windows.zip -OutFile pl.zip; Expand-Archive pl.zip -DestinationPath .; cd portable-laravel-windows; .\run.bat
```

---

[Linux](#linux) · [Windows](#windows) · [Comparative](#comparative)

---

## Linux

### Quick Start

```bash
chmod +x run.sh
./run.sh
```

Server starts on **http://127.0.0.1:8080** and the browser opens automatically.

---

### Building (Linux)

**Prerequisites** — no compilers needed, no root:

| Tool | Purpose | Install |
|------|---------|---------|
| `curl` | download PHP, Node, Composer | `apt install curl` / `dnf install curl` / `pacman -S curl` |
| `tar` | extract archives | usually pre-installed |
| `gzip` | compression | usually pre-installed |
| `git` | resolve paths | usually pre-installed |

**Clone and run:**

```bash
git clone https://github.com/your-user/portaravel.git
cd portaravel
chmod +x build-linux.sh
./build-linux.sh
```

Downloads everything on first run, caches in `dist/_cache/`. Subsequent runs reuse cache.

**What it does, step by step:**

1. Downloads a pre-built static PHP 8.4 CLI binary (`dl.static-php.dev`) — no compilation
2. Downloads the latest Composer PHAR (`getcomposer.org`)
3. Downloads Node.js 22 LTS tarball (`nodejs.org`)
4. Runs `composer create-project laravel/laravel`
5. Configures `.env` (SQLite, local mode, correct URLs)
6. Runs `npm install` + `npm run build` (Vite production assets)
7. Writes launcher scripts (`run.sh`, `stop.sh`, `shell.sh`, `vite.sh`, …)
8. Packages everything into `dist/portable-laravel-linux.tar.gz`

**Output:**

```
dist/
├── _cache/                          ← downloaded archives (reused on rebuild)
├── portable-laravel-linux/          ← ready-to-use distribution directory
└── portable-laravel-linux.tar.gz    ← distributable archive (~120 MB)
```

**Options:**

```bash
./build-linux.sh --force               # delete dist and rebuild from scratch
./build-linux.sh --skip-package        # skip creating the .tar.gz
./build-linux.sh --include-dev-tools   # also install Telescope, Debugbar, Pest, Rector
./build-linux.sh --dist-dir /tmp/out   # write output to a custom directory
```

---

### Directory Structure (Linux)

```
portable-laravel-linux/
├── php/               Static PHP 8.4.x
│   ├── bin/php        (statically compiled – no system libs required)
│   ├── php.ini        (regenerated at each launch from template)
│   └── php.ini.template
├── composer/
│   └── composer.phar
├── node/              Node.js 22.x LTS
│   ├── bin/node
│   ├── bin/npm
│   └── bin/npx
├── app/               Laravel application
│   ├── .env
│   ├── vendor/
│   ├── node_modules/
│   └── .vscode/
├── database/
│   └── database.sqlite
├── logs/
├── temp/
├── _env.sh            (shared env bootstrap)
├── run.sh             START HERE
├── shell.sh           Dev shell
├── artisan.sh         Artisan wrapper
├── composer.sh        Composer wrapper
├── npm.sh             npm wrapper
├── vite.sh            Vite dev server
└── stop.sh            Stop all processes
```

---

### Launcher Scripts (Linux)

| Script | Purpose |
|--------|---------|
| `run.sh` | Start Laravel + Vite, run migrations, open browser |
| `shell.sh` | Interactive bash with `php`, `composer`, `npm`, `artisan` in PATH |
| `vite.sh` | Standalone Vite HMR server (run alongside `run.sh`) |
| `artisan.sh` | Artisan wrapper |
| `composer.sh` | Composer wrapper |
| `npm.sh` | npm wrapper |
| `stop.sh` | Kill artisan serve (port 8080) and Vite (port 5173) |

```bash
# Custom port
LARAVEL_PORT=9090 ./run.sh

# Two-terminal HMR workflow
./run.sh       # Terminal 1
./vite.sh      # Terminal 2
```

---

### Vite / HMR (Linux)

Production assets are pre-built during the build step (`npm run build`).
Running `vite.sh` writes `public/hot` — Laravel automatically routes to the Vite dev server.
Stopping Vite removes `public/hot` and reverts to pre-built assets.

---

### Database (Linux)

```bash
./artisan.sh migrate
./artisan.sh migrate:fresh --seed
./artisan.sh tinker
sqlite3 database/database.sqlite    # requires system sqlite3
```

`app/.vscode/settings.json` has a pre-configured SQLTools connection.

---

### PHP Extensions (Linux)

Pre-built static binary (musl-linked, runs on any x86_64 Linux):

`bcmath` `bz2` `calendar` `ctype` `curl` `dom` `exif` `fileinfo` `filter` `ftp`
`gd` `gmp` `iconv` `mbstring` `mysqlnd` `openssl` `pcntl` `pdo` `pdo_mysql`
`pdo_sqlite` `pgsql` `pdo_pgsql` `phar` `posix` `session` `redis` `simplexml`
`soap` `sockets` `sqlite3` `tokenizer` `xml` `xmlreader` `xmlwriter` `zip` `zlib` `opcache`

---

### Troubleshooting (Linux)

**Port already in use:**
```bash
LARAVEL_PORT=9090 ./run.sh
```

**PHP binary won't execute:**
```bash
chmod +x php/bin/php
file php/bin/php        # should say "ELF 64-bit … statically linked"
```

**npm / Vite issues:**
```bash
rm -rf app/node_modules
./npm.sh install --prefix app
```

**Composer out of memory:** edit `php/php.ini.template`, increase `memory_limit`.

---

### Updating (Linux)

```bash
# Composer
curl -o composer/composer.phar https://getcomposer.org/composer.phar

# Node.js – download node-vXX.X.X-linux-x64.tar.gz from nodejs.org, extract over node/

# PHP – edit PHP_MINOR in build-linux.sh and re-run with --force
```

---

## Windows

### Quick Start

```
Double-click  run.bat
```

Server starts on **http://127.0.0.1:8080** and the browser opens automatically.

---

### Building (Windows)

**Prerequisites:**

- Windows 10/11 x64
- PowerShell 5.1+ (built into Windows) or PowerShell 7+
- Internet access (all components downloaded automatically)

**Allow script execution** (one-time, if needed):

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

**Clone and run:**

```powershell
git clone https://github.com/your-user/portaravel.git
cd portaravel
.\build-windows.ps1
```

**What it downloads:**

1. PHP 8.4 Thread Safe x64 ZIP (`windows.php.net`)
2. Xdebug DLL matching that PHP build (`xdebug.org`)
3. Composer PHAR (`getcomposer.org`)
4. Node.js 22 LTS ZIP (`nodejs.org`)
5. Laravel via `composer create-project`
6. npm dependencies + Vite production build

**Output:**

```
dist\
├── portable-laravel-windows\          ← ready-to-use distribution directory
└── portable-laravel-windows.zip       ← distributable archive
```

---

### Directory Structure (Windows)

```
portable-laravel-windows/
├── php/               PHP 8.4.x Thread Safe x64
│   ├── php.exe
│   ├── php.ini        (regenerated at each launch from template)
│   ├── php.ini.template
│   └── ext/
│       └── php_xdebug.dll
├── composer/
│   └── composer.phar
├── node/              Node.js 22.x LTS
│   ├── node.exe
│   └── npm.cmd
├── app/               Laravel application
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
```

---

### Launcher Scripts (Windows)

| Script | Purpose |
|--------|---------|
| `run.bat` | Start Laravel + Vite, run migrations, open browser |
| `shell.bat` | CMD with all tools in PATH |
| `vite.bat` | Standalone Vite HMR server |
| `artisan.bat` | Artisan wrapper |
| `composer.bat` | Composer wrapper |
| `npm.bat` | npm wrapper |
| `stop.bat` | Kill server and Vite by port |

---

### Vite / HMR (Windows)

Production assets are pre-built during the build step (`npm run build`).
Running `vite.bat` writes `public/hot` — Laravel automatically routes to the Vite dev server.
Stopping Vite removes `public/hot` and reverts to pre-built assets.

---

### Database (Windows)

```cmd
artisan.bat migrate
artisan.bat migrate:fresh --seed
artisan.bat tinker
```

`app/.vscode/settings.json` has a pre-configured SQLTools connection.

---

### Xdebug (Windows)

Xdebug is pre-configured (3.4.x).

| Setting | Value |
|---------|-------|
| Mode | develop, debug, profile |
| Port | 9003 |
| Client | 127.0.0.1 |
| IDE key | VSCODE |

**VSCode:** Install *PHP Debug* (`xdebug.php-debug`), open `app/`, press F5 → *Listen for Xdebug*.

**PHPStorm:** Settings → PHP → Debug → port 9003. Add server `127.0.0.1:8080`. Click phone icon.

**Disable for performance:**
```cmd
set XDEBUG_MODE=off && run.bat
```

---

### Troubleshooting (Windows)

**Port already in use:** edit `_env.bat`, change `LARAVEL_PORT=8080`.

**PHP extension not loading:**
```cmd
shell.bat
php -m
```
Check `logs\php_errors.log`.

**Xdebug not connecting:** verify port 9003 not blocked by Windows Firewall.

**npm / Vite issues:**
```cmd
rmdir /s /q app\node_modules
npm.bat install --prefix app
```

**Composer out of memory:** edit `php\php.ini.template`, increase `memory_limit`.

---

### Updating (Windows)

```powershell
# Composer
curl -o composer\composer.phar https://getcomposer.org/composer.phar
```

Node.js — download `node-vXX.X.X-win-x64.zip` from https://nodejs.org, extract over `node\`.

PHP — download PHP TS ZIP from https://windows.php.net/download, extract to `php\`.
Download matching Xdebug DLL from https://xdebug.org, place in `php\ext\php_xdebug.dll`.

---

## Comparative

| | Linux | Windows |
|---|---|---|
| PHP | 8.4.x static binary | 8.4.x Thread Safe x64 |
| PHP source | dl.static-php.dev (pre-built, musl) | windows.php.net |
| Laravel | 13.x | 12.x |
| Composer | latest | latest |
| Node.js LTS | 22.x | 22.x |
| Xdebug | — | 3.4.x |
| Database | SQLite | SQLite |
| Server | `php artisan serve` | `php artisan serve` |
| Build time | ~1–2 min | ~3–5 min |
| Build requires | `curl tar gzip git` | PowerShell 5.1+ |
| Root / admin | not required | not required |
| Arch | x86_64 | x64 |
| PHP linked | fully static (musl) | DLL-based |
| Runs on | any Linux x86_64 distro | Windows 10/11 |

> Linux PHP is musl-linked and carries zero host library dependencies — copy the folder to any x86_64 Linux machine and it runs unchanged.

---

*Linux: `build-linux.sh` · Windows: `build-windows.ps1`*
