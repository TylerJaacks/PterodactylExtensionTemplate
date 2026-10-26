# Pterodactyl 2.0 extension template

The Pterodactyl Panel is built into a Docker image. This folder holds only your extensions and the
few files that run them:

```
compose.yaml   the stack: MariaDB, Redis, and the Panel, queue and scheduler from the image
Dockerfile     the image: Panel source at PANEL_REF (built), PHP 8.4, Node 22, the ptx CLI
ptx, ptx.cmd   helpers for macOS/Linux/WSL and for Windows
extensions/    your extensions: commit these
```

## Quick start

```sh
./ptx up                          # Windows: ptx up. The first run builds the image (several minutes)
./ptx new my-ext --name="My Ext"  # scaffolds extensions/my-ext
./ptx dev my-ext                  # rebuilds and republishes on save; the open page reloads itself
./ptx pack my-ext                 # checks it, then writes extensions/my-ext/my-ext-1.0.0.pteroext
```

Open http://localhost:8000 and sign in as `admin` / `password`. There's no Wings: a **Dev Server**
is seeded on a placeholder node so server screens and APIs work, but it shows as offline.

## Commands

| Command | |
| --- | --- |
| `ptx up` | Build the image if needed and start the stack. Re-run it after changing `.env`. |
| `ptx down [-v]` | Stop the stack. `-v` also deletes the database and Panel state. |
| `ptx logs [service]` | Follow the panel, queue and scheduler logs. |
| `ptx new <id> [options]` | Scaffold `extensions/<id>` and install its dependencies. Options: `--name`, `--description`, `--author`, `--prefix`, `--no-ui`. |
| `ptx dev [id]` | Build, enable (runs migrations) and watch. Ctrl-C stops watching. |
| `ptx test [id]` | Typecheck, tests, production build, PHP lint, `p:extension:doctor`. |
| `ptx pack [id]` | `ptx test`, then package the extension. |
| `ptx npm [id] <args>` | npm inside an extension, e.g. `ptx npm my-ext install date-fns`. |
| `ptx artisan <args>` | Any artisan command, e.g. `ptx artisan p:extension:list`. |
| `ptx reset [-y]` | Wipe the database, recreate the admin and Dev Server, re-enable every extension. |

`up`, `down` and `logs` run Docker Compose. The rest run inside the Panel container, so
`docker compose exec panel ptx <command>` does the same thing without the helpers. `[id]` can be
left out when there's only one extension.

## How it works

- Only `./extensions` is mounted into the containers, at the Panel's extensions directory. The
  database, the Panel's `.env` and its storage live in Docker volumes.
- Every start runs the `setup` service once: it migrates, seeds an empty database, and builds and
  enables any extension not yet enabled against the current image. A fresh clone of a repo made
  from this template comes up with all its extensions enabled.
- The SDK ships in the image and is copied to `extensions/.sdk` (gitignored). Extensions link it as
  `file:../.sdk`, which resolves both in the container and on your machine, so your editor gets
  the SDK's types. An extension made against a Panel checkout (`file:../../packages/sdk`) is
  re-linked automatically.
- The containers run as your user (`DEV_UID`/`DEV_GID`), so what they write to `extensions/` is yours.

## Settings (`.env`)

| Key | Default | |
| --- | --- | --- |
| `PANEL_REF` | `v2.0.0-beta.2` | Panel tag or branch. Change it, then `ptx up`: the image rebuilds and every extension is rebuilt against the new SDK. |
| `PANEL_PORT` | `8000` | Give each copy of the template its own port to run several side by side. |
| `APP_URL` | `http://localhost:$PANEL_PORT` | Set it when you open the Panel from another machine. |
| `ADMIN_USERNAME` / `ADMIN_PASSWORD` / `ADMIN_EMAIL` | `admin` / `password` | Created on first run and after `ptx reset`. |

## Notes

- **Windows:** keep the template in your WSL filesystem and use `./ptx` from a WSL shell. Docker
  Desktop doesn't reliably pass file-change events from `C:\` folders into containers, so
  `ptx dev` can miss your saves there. `ptx.cmd` works for everything else.
- **Older `PANEL_REF`:** migrations from a newer one can't be undone. Run `ptx reset` if the Panel
  errors afterwards.
- **CI:** `./ptx` drops the TTY when it isn't attached to a terminal (use `ptx reset -y` there).
- **Laravel log:** `docker compose exec panel tail -f storage/logs/laravel.log`.
