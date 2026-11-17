#!/usr/bin/env bash
# Rehearses blue/green deploys on this machine, against a copy of the
# Contabo layout: the repo's docker-compose.yml, nginx config and slots.sh,
# with a self-signed certificate and dummy secrets. Real browsers (Playwright)
# sit in a game, the public queue and a private lobby while slots.sh moves
# the site from blue to green and back, and the checks in scenario.py say
# whether each of them ended up where they should.
#
#   deploy/contabo/test/run.sh [--image IMAGE] [--keep]
#
#   --image IMAGE   test this image instead of building Dockerfile.prod
#   --keep          leave the containers running afterwards (prints how to stop them)
#
# Needs docker (with compose) or podman (with a compose provider and the
# user podman.socket), python3 and openssl. Takes about 5 minutes after the
# image is built. Exit 0 means every check passed.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
contabo=$(dirname "$here")
repo=$(cd "$contabo/../.." && pwd)
image="" keep=0
while [ $# -gt 0 ]; do
  case $1 in
    --image) image=${2:?}; shift ;;
    --keep) keep=1 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

if command -v docker >/dev/null; then
  DOCKER=docker
  COMPOSE="docker compose"
elif command -v podman >/dev/null; then
  DOCKER=podman
  export DOCKER_HOST=${DOCKER_HOST:-unix://${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock}
  export PODMAN_COMPOSE_WARNING_LOGS=false
  COMPOSE="podman compose"
else
  echo "needs docker or podman" >&2; exit 1
fi
export COMPOSE

project=ff-deploy-test
port=${FF_TEST_PORT:-18443}
cache=${XDG_CACHE_HOME:-$HOME/.cache}/ff-deploy-test
work=$(mktemp -d)/fortyfives
mkdir -p "$work" "$cache"
export COMPOSE_PROJECT_NAME=$project

cleanup() {
  if [ $keep = 1 ]; then
    echo "left running in $work; stop with:"
    echo "  cd $work && COMPOSE_PROJECT_NAME=$project $COMPOSE down && $DOCKER volume rm ${project}_app_data ${project}_sqlite_backups ${project}_db_data"
    return
  fi
  (cd "$work" && $COMPOSE down --remove-orphans >/dev/null 2>&1) || true
  $DOCKER volume rm -f "${project}_app_data" "${project}_sqlite_backups" "${project}_db_data" >/dev/null 2>&1 || true
  rm -rf "$(dirname "$work")"
}
trap cleanup EXIT

echo "==> Images"
if [ -z "$image" ]; then
  image=localhost/$project:a
  $DOCKER build -q -f "$repo/Dockerfile.prod" -t "$image" "$repo" >/dev/null
fi
# A second image that differs from the first, as a new release would.
image_b=localhost/$project:b
printf 'FROM %s\nLABEL ff.deploy-test=b\n' "$image" | $DOCKER build -q -t "$image_b" - >/dev/null
echo "a: $image"
echo "b: $image_b"

echo "==> Project in $work"
cp "$contabo/slots.sh" "$work/"
mkdir -p "$work/nginx/conf.d" "$work/nginx/slot" "$work/scripts" "$work/certbot/www" \
  "$work/letsencrypt/live/fortyfives.net"
cp "$contabo/nginx/conf.d/site.conf" "$work/nginx/conf.d/"
cp "$repo/scripts/backup-sqlite.sh" "$work/scripts/"
# Start as production does after a deploy to blue.
sed -e 's/^# live=.*/# live=blue draining=-/' -e 's/default web-.*;/default web-blue;/' \
  -e '/"~^:/d' "$contabo/nginx/slot/live.conf" > "$work/nginx/slot/live.conf"
# The production file, with local images, ports, certificate and volumes.
sed -E \
  -e "s#image: docker.io/thwar/fortyfives.net@sha256:[0-9a-f]{64}#image: $image#" \
  -e "s#^    - 80:80\$##" \
  -e "s#^    - 443:443\$#    - 127.0.0.1:$port:443#" \
  -e "s#/etc/letsencrypt:/etc/letsencrypt#./letsencrypt:/etc/letsencrypt#" \
  -e "s#name: fortyfives_#name: ${project}_#" \
  -e 's#^(    - \./[^ ]+):ro$#\1:ro,z#' \
  "$contabo/docker-compose.yml" | grep -v '^$' > "$work/docker-compose.yml"
awk '/^  web-blue:/{s=1} /^  web-green:/{s=2} s==1 && /^    scale:/{$0="    scale: 1"} s==2 && /^    scale:/{$0="    scale: 0"} {print}' \
  "$work/docker-compose.yml" > "$work/c.tmp" && mv "$work/c.tmp" "$work/docker-compose.yml"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=fortyfives.net \
  -addext subjectAltName=DNS:fortyfives.net,DNS:www.fortyfives.net \
  -keyout "$work/letsencrypt/live/fortyfives.net/privkey.pem" \
  -out "$work/letsencrypt/live/fortyfives.net/fullchain.pem" 2>/dev/null
cat > "$work/.env" <<EOF
SECRET_KEY_BASE=$(openssl rand -hex 48)
PHX_SERVER=true
AWS_ACCESS_KEY_ID=deploy-test
AWS_SECRET_ACCESS_KEY=deploy-test
GOOGLE_CLIENT_ID=deploy-test
GOOGLE_CLIENT_SECRET=deploy-test
TURNSTILE_ENABLED=false
EOF
for v in app_data sqlite_backups db_data; do
  $DOCKER volume rm -f "${project}_$v" >/dev/null 2>&1 || true
  $DOCKER volume create "${project}_$v" >/dev/null
done
# The app runs as a non-root user and needs to write the volume.
$DOCKER run --rm -v "${project}_app_data:/data" --user root --entrypoint sh "$image" -c 'chown app:app /data'

echo "==> Starting blue, nginx and db_backup"
(cd "$work" && $COMPOSE up -d --quiet-pull web-blue nginx db_backup)
# site.conf asks Docker's DNS (127.0.0.11); podman's lives elsewhere.
dns=$(cd "$work" && $COMPOSE exec -T nginx sed -n 's/^nameserver //p' /etc/resolv.conf | head -1)
if [ "$dns" != 127.0.0.11 ]; then
  sed "s/resolver 127.0.0.11 /resolver $dns /" "$contabo/nginx/conf.d/site.conf" > "$work/nginx/conf.d/site.conf"
  (cd "$work" && $COMPOSE exec -T nginx nginx -s reload)
fi
for _ in $(seq 1 60); do
  [ "$(cd "$work" && $COMPOSE exec -T web-blue wget -qO- http://127.0.0.1:4000/healthz 2>/dev/null)" = ok ] && break
  sleep 2
done

echo "==> Browser"
venv=$cache/venv
if [ ! -x "$venv/bin/python" ]; then
  python3 -m venv "$venv"
fi
"$venv/bin/pip" install -q -r "$here/requirements.txt"
"$venv/bin/python" -m playwright install chromium >/dev/null

echo "==> Scenario"
"$venv/bin/python" "$here/scenario.py" --dir "$work" --port "$port" --image-a "$image" --image-b "$image_b"
