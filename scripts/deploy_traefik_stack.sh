#!/usr/bin/env bash
set -euo pipefail

: "${GIT_REPO:?}"; : "${SSH_USER:?}"; : "${HOST_IP:?}"
: "${DOMAIN:?}"; : "${LETSENCRYPT_EMAIL:?}"

echo "👉 Проверяю DNS A-запись домена"
dns_ip="$(getent ahostsv4 "$DOMAIN" | awk '{print $1; exit}')"
echo "DNS: $dns_ip | EXPECT: $HOST_IP"
[ "$dns_ip" = "$HOST_IP" ] || { echo "❌ $DOMAIN не указывает на $HOST_IP"; exit 1; }

echo "👉 Проверяю SSH-доступ"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${SSH_USER}@${HOST_IP}" "id >/dev/null"

echo "👉 Установка Docker (если отсутствует)"
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
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
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

echo "👉 Клонирую/обновляю репозиторий на сервере"
ssh "${SSH_USER}@${HOST_IP}" "mkdir -p /opt/meteor && \
  if [ -d /opt/meteor/.git ]; then git -C /opt/meteor pull --ff-only; \
  else git clone --depth=1 '$GIT_REPO' /opt/meteor; fi"

echo "👉 Подготавливаю папки и .env для Traefik"
ssh "${SSH_USER}@${HOST_IP}" "cd /opt/meteor/infra/traefik && \
  mkdir -p letsencrypt && \
  install -m 600 /dev/null letsencrypt/acme.json || true && \
  cp -n .env.example .env || true && \
  sed -i 's|^DOMAIN=.*|DOMAIN=${DOMAIN}|' .env && \
  sed -i 's|^LETSENCRYPT_EMAIL=.*|LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL}|' .env"

echo "👉 Стартую прокси и тестовый сервис"
ssh "${SSH_USER}@${HOST_IP}" "cd /opt/meteor/infra/traefik && \
  docker compose --env-file ./.env up -d"

echo "👉 Жду выпуск сертификата и доступность HTTPS"
for i in {1..30}; do
  code="$(curl -skI --resolve "${DOMAIN}:443:${HOST_IP}" "https://${DOMAIN}/" | awk 'NR==1{print $2}')" || true
  [[ "$code" =~ ^2|3 ]] && { echo "✅ HTTPS работает (код $code)"; exit 0; }
  echo "… ожидание (${i}/30)"; sleep 5
done
echo "❌ Не дождались валидного ответа по HTTPS"; exit 1
