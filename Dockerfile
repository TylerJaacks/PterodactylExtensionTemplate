# syntax=docker/dockerfile:1
# Dev image for Pterodactyl Panel 2.0 extensions: the Panel source at PANEL_REF, built with its dev
# dependencies, plus PHP 8.4, Node 22, Composer and the `ptx` dev CLI. compose.yaml builds this.
FROM node:22-alpine3.23 AS node

FROM php:8.4-cli-alpine3.23
RUN apk add --no-cache git libstdc++ libgcc freetype icu-libs icu-data-full libjpeg-turbo libpng libwebp libzip mariadb-client \
 && apk add --no-cache --virtual .build-deps $PHPIZE_DEPS freetype-dev icu-dev libjpeg-turbo-dev libpng-dev libwebp-dev libzip-dev \
 && docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
 && docker-php-ext-install -j"$(nproc)" bcmath gd intl pcntl pdo_mysql zip \
 && apk del .build-deps \
 && printf 'memory_limit=1G\n' > "$PHP_INI_DIR/conf.d/zz-dev.ini"
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
# npm 11: npm 10 crashes ("reading 'edgesOut'") installing an extension that links the SDK.
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
 && npm install -g npm@11 --no-audit --no-fund
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer

# The Panel. A tag is fetched once; a branch is fetched again whenever it moves.
ARG PANEL_REF=v2.0.0-beta.2
ADD --keep-git-dir=true https://github.com/pterodactyl/panel.git#${PANEL_REF} /app
WORKDIR /app
RUN --mount=type=cache,target=/tmp/composer-cache \
    COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_CACHE_DIR=/tmp/composer-cache composer install --no-interaction --no-progress
RUN --mount=type=cache,target=/root/.npm \
    npm ci --no-audit --no-fund && npm run build && npm run sdk:testing

# Runtime layout. The SDK moves to /opt/pterodactyl-sdk and `ptx bootstrap` copies it to
# extensions/.sdk on the bind mount, where packages/sdk now points: new extensions link it as
# file:../.sdk, a path that resolves on your machine (editor types) and in here (builds, tests).
# The container runs as your user, so the paths it writes are open to any uid.
RUN printf '%s@%s\n' "$PANEL_REF" "$(git rev-parse --short=12 HEAD)" > .ptx-build \
 && mv packages/sdk /opt/pterodactyl-sdk && ln -s /app/extensions/.sdk packages/sdk \
 && mkdir -p var extensions public/assets/extensions /home/dev \
 && ln -s var/.env .env \
 && chmod -R a+rwX storage bootstrap/cache var extensions public/assets/extensions \
 && chmod 1777 /home/dev
ENV HOME=/home/dev COMPOSER_HOME=/home/dev/.composer

COPY --chmod=755 <<'PTX' /usr/local/bin/ptx
#!/bin/sh
# ptx: dev CLI for Pterodactyl extensions. Your extensions/ folder is mounted at /app/extensions.
# Run it in the panel container: docker compose exec panel ptx <command>  (or ./ptx, ptx.cmd).
set -eu
cd /app
EXT=/app/extensions
BUILD=$(cat /app/.ptx-build)

die()  { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
artisan() { php /app/artisan "$@"; }

usage() {
  cat <<'USAGE'
ptx: Pterodactyl extension dev CLI

  new <id> [--name=..] [--description=..] [--author=..] [--prefix=..] [--no-ui]
                   scaffold extensions/<id> and install its dependencies
  dev [id]         build, enable and watch; saves republish and the page reloads
  test [id]        typecheck, tests, build, PHP lint, p:extension:doctor
  pack [id]        test, then write extensions/<id>/<id>-<version>.pteroext
  npm [id] <args>  npm inside an extension
  artisan <args>   php artisan in the Panel
  reset [-y]       wipe the database; recreate the admin and Dev Server; re-enable extensions
  bootstrap        first-run setup (the setup service runs it on every start)

[id] can be left out when there's only one extension.
USAGE
}

ids() {
  for m in "$EXT"/*/extension.json; do
    [ -f "$m" ] && basename "$(dirname "$m")"
  done
  return 0
}

# The extension a command acts on: the id given, or the only one there is.
pick() {
  c=$1
  if [ -n "${2:-}" ]; then
    [ -f "$EXT/$2/extension.json" ] || die "No extension at extensions/$2."
    echo "$2"
    return
  fi
  # shellcheck disable=SC2046 # ids are slugs
  set -- $(ids)
  case $# in
    0) die "No extensions yet. Create one: ptx new <id>" ;;
    1) echo "$1" ;;
    *) die "Several extensions: $*. Name one: ptx $c <id>" ;;
  esac
}

# Copy this image's SDK to extensions/.sdk (once per image).
sync_sdk() {
  [ "$(cat "$EXT/.sdk/.ptx-build" 2>/dev/null)" = "$BUILD" ] && return 0
  info "Copying the SDK from Panel $BUILD to extensions/.sdk"
  rm -rf "$EXT/.sdk.tmp"
  cp -R /opt/pterodactyl-sdk "$EXT/.sdk.tmp"
  echo "$BUILD" > "$EXT/.sdk.tmp/.ptx-build"
  rm -rf "$EXT/.sdk"
  mv "$EXT/.sdk.tmp" "$EXT/.sdk"
}

# Extensions made against a Panel checkout link the SDK as file:../../packages/sdk. That works in
# here, but the link dangles on your machine, so point it at file:../.sdk instead.
relink() {
  pkg=$EXT/$1/package.json
  [ -f "$pkg" ] || return 0
  grep -q '"@pterodactyl/sdk": *"file:\.\./\.\./packages/sdk"' "$pkg" || return 0
  sed -i 's#"@pterodactyl/sdk": *"file:\.\./\.\./packages/sdk"#"@pterodactyl/sdk": "file:../.sdk"#' "$pkg"
  rm -rf "$EXT/$1/node_modules/@pterodactyl/sdk"
  warn "$1: now links @pterodactyl/sdk as file:../.sdk"
}

# Install node_modules when they're missing or the SDK link is broken.
deps() {
  sync_sdk
  relink "$1"
  [ -f "$EXT/$1/package.json" ] || return 0
  [ -e "$EXT/$1/node_modules/@pterodactyl/sdk/package.json" ] && return 0
  info "$1: installing dependencies"
  (cd "$EXT/$1" && npm install --no-audit --no-fund)
}

# Build, install and enable (runs migrations).
enable_ext() {
  deps "$1" && info "$1: building and enabling" && artisan p:extension:dev "$EXT/$1" --enable
}

bootstrap() {
  mkdir -p storage/app/private storage/framework/cache/data storage/framework/sessions \
    storage/framework/views storage/logs
  if [ ! -f var/.env ]; then
    cp .env.example var/.env
    grep -q '^HASHIDS_SALT=' var/.env || echo 'HASHIDS_SALT=' >> var/.env
    artisan key:generate --force --no-interaction
    sed -i "s|^HASHIDS_SALT=.*|HASHIDS_SALT=$(php -r 'echo bin2hex(random_bytes(20));')|" var/.env
  fi
  sync_sdk
  artisan migrate --force --no-interaction

  # An empty database: eggs, an admin, and a Wings-less server for server-area screens.
  users=$(artisan tinker --execute='echo \Pterodactyl\Models\User::query()->count();' 2>/dev/null | tail -n1)
  if [ "$users" = 0 ]; then
    rm -f var/enabled-*
    artisan db:seed --force --no-interaction
    artisan p:user:make --admin=1 --email="$ADMIN_EMAIL" --username="$ADMIN_USERNAME" \
      --name-first=Dev --name-last=Admin --password="$ADMIN_PASSWORD" --no-interaction
    artisan tinker --execute="$(cat <<'PHP'
$owner = \Pterodactyl\Models\User::query()->where('root_admin', true)->firstOrFail();
$location = \Pterodactyl\Models\Location::factory()->create(['short' => 'dev', 'long' => 'Local development']);
$node = \Pterodactyl\Models\Node::factory()->create(['location_id' => $location->id, 'name' => 'dev-node', 'fqdn' => '127.0.0.1']);
$allocation = \Pterodactyl\Models\Allocation::factory()->create(['node_id' => $node->id, 'ip' => '127.0.0.1', 'port' => 25565]);
$server = \Pterodactyl\Models\Server::factory()->create([
    'owner_id' => $owner->id,
    'node_id' => $node->id,
    'allocation_id' => $allocation->id,
    'egg_id' => \Pterodactyl\Models\Egg::query()->firstOrFail()->id,
    'name' => 'Dev Server',
]);
\Pterodactyl\Models\Allocation::query()->whereKey($allocation->id)->update(['server_id' => $server->id]);
echo "Seeded test server {$server->uuidShort}\n";
PHP
)"
  fi

  # Build and enable each extension not yet enabled against this image.
  for id in $(ids); do
    [ "$(cat "var/enabled-$id" 2>/dev/null)" = "$BUILD" ] && continue
    if enable_ext "$id"; then
      echo "$BUILD" > "var/enabled-$id"
    else
      warn "$id: couldn't enable it. Fix it, then run: ptx dev $id"
    fi
  done
  info "Panel ready at $APP_URL (login: $ADMIN_USERNAME / $ADMIN_PASSWORD)"
}

new() {
  id=${1:-}
  case $id in
    '' | -*) die "Usage: ptx new <id> [--name=..] [--description=..] [--author=..] [--prefix=..] [--no-ui]" ;;
  esac
  [ ! -e "$EXT/$id" ] || die "extensions/$id already exists."
  artisan p:extension:make "$@"
  deps "$id"
  info "Created extensions/$id. Next: ptx dev $id"
}

dev() {
  id=$(pick dev "${1:-}")
  deps "$id"
  info "Watching $id. Open $APP_URL  (Ctrl-C to stop)"
  exec php /app/artisan p:extension:dev "$EXT/$id" --enable --watch
}

check() {
  id=$(pick test "${1:-}")
  deps "$id"
  d=$EXT/$id
  if [ -f "$d/package.json" ]; then
    info "$id: typecheck"; (cd "$d" && npm run typecheck)
    info "$id: tests";     (cd "$d" && npm test)
    info "$id: build";     (cd "$d" && npm run build)
  fi
  info "$id: PHP lint"
  out=$(cd "$d" && find . \( -name node_modules -o -name vendor \) -prune -o -name '*.php' -exec php -l {} + 2>&1) \
    || { printf '%s\n' "$out" | grep -v '^No syntax errors'; exit 1; }
  info "$id: doctor"
  artisan p:extension:doctor "$d"
  info "$id: all checks passed"
}

pack() {
  id=$(pick pack "${1:-}")
  check "$id"
  info "$id: packing"
  # Without --output, p:extension:pack writes <id>-<version>.pteroext to the working directory.
  (cd "$EXT/$id" && artisan p:extension:pack "$EXT/$id" --force)
  # shellcheck disable=SC2012 # archive names are <id>-<version>.pteroext
  info "Packed: extensions/$id/$(cd "$EXT/$id" && ls -t "$id"-*.pteroext | sed -n 1p)"
}

npm_in() {
  if [ -n "${1:-}" ] && [ -f "$EXT/$1/extension.json" ]; then
    id=$1
    shift
  else
    id=$(pick npm)
  fi
  [ $# -gt 0 ] || die "Usage: ptx npm [id] <npm args>"
  sync_sdk
  relink "$id"
  cd "$EXT/$id"
  exec npm "$@"
}

reset() {
  if [ "${1:-}" != -y ]; then
    printf 'Wipe the dev database (users, servers, extension data)? [y/N] '
    read -r answer || answer=
    case $answer in y | Y | yes) ;; *) exit 1 ;; esac
  fi
  PTERODACTYL_EXTENSIONS_ENABLED=false artisan db:wipe --force --no-interaction
  artisan cache:clear --no-interaction
  rm -f var/enabled-*
  bootstrap
}

cmd=${1:-help}
[ $# -gt 0 ] && shift
case $cmd in
  new) new "$@" ;;
  dev) dev "$@" ;;
  test) check "$@" ;;
  pack) pack "$@" ;;
  npm) npm_in "$@" ;;
  artisan) exec php /app/artisan "$@" ;;
  reset) reset "$@" ;;
  bootstrap) bootstrap ;;
  help | -h | --help) usage ;;
  *) usage >&2; exit 1 ;;
esac
PTX
