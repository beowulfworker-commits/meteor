#!/usr/bin/env bash
set -euo pipefail

: "${DOMAIN:?}"; : "${HOST_IP:?}"; : "${SSH_USER:?}"; : "${LETSENCRYPT_EMAIL:?}"

echo "👉 Проверка, что DNS A-запись домена указывает на нужный IP"
dns_ip="$(getent ahostsv4 "$DOMAIN" | awk '{print $1; exit}')"
echo "DNS: $dns_ip | EXPECT: $HOST_IP"
[ "$dns_ip" = "$HOST_IP" ] || { echo "❌ $DOMAIN не указывает на $HOST_IP"; exit 1; }

echo "👉 SSH-доступ"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${SSH_USER}@${HOST_IP}" "id >/dev/null"

echo "👉 Установка Docker (если не установлен)"
ssh "${SSH_USER}@${HOST_IP}" 'set -e
if ! command -v docker >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg lsb-release
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release; echo "$ID") $(. /etc/os-release; echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker || service docker start || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf -y install dnf-plugins-core || true
    dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo || true
    dnf -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable --now docker || true
  elif command -v yum >/dev/null 2>&1; then
    yum -y install yum-utils
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    yum -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable --now docker || true
  else
    echo "Unsupported OS: install docker manually"; exit 1
  fi
fi
'

echo "👉 Подготовка каталога /opt/meteor"
ssh "${SSH_USER}@${HOST_IP}" 'set -e
mkdir -p /opt/meteor/letsencrypt
install -m 600 /dev/null /opt/meteor/letsencrypt/acme.json || true
'

echo "👉 Создаю .env с переменными для compose"
ssh "${SSH_USER}@${HOST_IP}" "printf 'DOMAIN=%s\nLETSENCRYPT_EMAIL=%s\n' '$DOMAIN' '$LETSENCRYPT_EMAIL' | tee /opt/meteor/.env >/dev/null"

echo "👉 Пишу docker-compose.yml (Traefik + whoami)"
ssh "${SSH_USER}@${HOST_IP}" 'cat > /opt/meteor/docker-compose.yml <<'"'"'YAML'"'"'
version: "3.9"
services:
  traefik:
    image: traefik:v2.11
    command:
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --api.dashboard=true
      - --certificatesresolvers.le.acme.email=${LETSENCRYPT_EMAIL}
      - --certificatesresolvers.le.acme.storage=/letsencrypt/acme.json
      - --certificatesresolvers.le.acme.httpchallenge=true
      - --certificatesresolvers.le.acme.httpchallenge.entrypoint=web
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./letsencrypt:/letsencrypt
    restart: unless-stopped
    networks: [web]

  whoami:
    image: traefik/whoami
    labels:
      - traefik.enable=true
      - traefik.http.routers.meteor.rule=Host(`${DOMAIN}`)
      - traefik.http.routers.meteor.entrypoints=websecure
      - traefik.http.routers.meteor.tls=true
      - traefik.http.routers.meteor.tls.certresolver=le
      # Глобальный редирект HTTP -> HTTPS
      - traefik.http.routers.redirect.rule=HostRegexp(`{host:.+}`)
      - traefik.http.routers.redirect.entrypoints=web
      - traefik.http.routers.redirect.middlewares=redirect-web-secure
      - traefik.http.routers.redirect.service=noop@internal
      - traefik.http.middlewares.redirect-web-secure.redirectscheme.scheme=https
    networks: [web]
    restart: unless-stopped

networks:
  web: {}
YAML
'

echo "👉 Стартую Traefik + whoami"
ssh "${SSH_USER}@${HOST_IP}" 'cd /opt/meteor && docker compose up -d'

echo "👉 Ожидаю получение сертификата и доступность HTTPS"
for i in {1..30}; do
  code="$(curl -skI --resolve "${DOMAIN}:443:${HOST_IP}" "https://${DOMAIN}/" | awk "NR==1{print \$2}")" || true
  [[ "$code" =~ ^2|3 ]] && { echo "✅ HTTPS работает, код $code"; break; }
  echo "… ждём, пока Traefik получит сертификат (попытка $i/30)"
  sleep 5
done
