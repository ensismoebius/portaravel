# Portable Laravel – Windows Development Environment

> **Extract. Run. Code.** No installation, no admin rights, no system changes.

## Quick Start

`
Double-click  run.bat
`

Server starts on **http://127.0.0.1:8080** and the browser opens automatically.

The web server is **php artisan serve** – Laravel's built-in development server.

---

## Included Versions

| Component   | Version     |
|-------------|-------------|
| PHP         | 8.4.21     |
| Laravel     | 12.59.0 |
| Composer    | 2.10|
| Node.js LTS | 22.22.3    |
| Xdebug      | 3.4.0      |
| Database    | SQLite      |

---

## Directory Structure

```
portable-laravel-windows/
├── php/               PHP 8.4.21 Thread Safe x64
│   ├── php.exe
│   ├── php.ini        (regenerated at each launch from template)
│   ├── php.ini.template
│   └── ext/
│       └── php_xdebug.dll
├── composer/
│   └── composer.phar
├── node/              Node.js 22.22.3 LTS
│   ├── node.exe
│   └── npm.cmd
├── app/               Laravel 12.59.0 application
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

## Web Server

This distribution uses **php artisan serve** – Laravel's built-in PHP development server.
It runs on http://127.0.0.1:8080 and is perfect for local development.

To use a different port:
1. Edit `_env.bat`
2. Change `LARAVEL_PORT=8080` to your desired port
3. Re-run `run.bat`

---

## Launcher Scripts

### run.bat
Starts Laravel server, runs migrations, opens browser.

### shell.bat
Opens CMD with php, composer, npm, artisan in PATH:
```cmd
artisan migrate
artisan make:controller UserController --resource
artisan route:list
artisan tinker
```

### vite.bat
Starts Vite HMR server. Run alongside `run.bat`:
```
Window 1:  run.bat
Window 2:  vite.bat
```

### artisan.bat
```
artisan.bat migrate
artisan.bat make:model Post --migration --controller
```

### composer.bat
```
composer.bat require guzzlehttp/guzzle
composer.bat dump-autoload -o
```

### npm.bat
```
npm.bat install some-package
npm.bat run build
```

### stop.bat
Kills the Laravel server and Vite process by port.

---

## Xdebug

Xdebug **3.4.0** is pre-configured and starts with every request.

| Setting | Value |
|---------|-------|
| Mode | develop, debug, profile |
| Port | 9003 |
| Client | 127.0.0.1 |
| IDE key | VSCODE |

### VSCode Setup
1. Install **PHP Debug** (xdebug.php-debug)
2. Open the `app/` folder in VSCode
3. Press **F5** → *Listen for Xdebug*
4. Set a breakpoint and open http://127.0.0.1:8080

### PHPStorm Setup
1. Settings → PHP → Debug → Xdebug – port **9003**
2. Settings → PHP → Servers – add `127.0.0.1:8080`
3. Click the phone icon → start listening
4. Set a breakpoint and refresh the browser

### Disable Xdebug (for performance)
```cmd
set XDEBUG_MODE=off
run.bat
```

---

## Database (SQLite)

File: `database\database.sqlite`

```
artisan.bat migrate
artisan.bat migrate:fresh --seed
artisan.bat tinker
```

The SQLite Tools extension for VSCode provides a GUI browser:
`app/.vscode/settings.json` has the connection pre-configured.

---

## Troubleshooting

### Port already in use
Edit `_env.bat`, change `LARAVEL_PORT=8080` to another port.

### PHP extension not loading
```
shell.bat
> php -m
```
Check `logs\php_errors.log` for details.

### Xdebug not connecting
Verify port 9003 is not blocked by Windows Firewall.
Run `php -d xdebug.mode=debug -m` to confirm Xdebug loads.

### Composer out of memory
Edit `php\php.ini.template`, increase `memory_limit`.

---

## Updating Components

### Update Composer
Replace `composer\composer.phar` from https://getcomposer.org/composer.phar

### Update Node.js
Download `node-vXX.X.X-win-x64.zip` from https://nodejs.org and extract over `node\`.

### Update PHP
Download PHP TS ZIP from https://windows.php.net/download, extract to `php\`.
Download matching Xdebug DLL from https://xdebug.org, place in `php\ext\php_xdebug.dll`.

---

*Built with build-windows.ps1 – Portable Laravel Distribution Builder*
