#!/usr/bin/env bash
set -euo pipefail

echo "👉 Проверяю переменные:"
: "${DOMAIN:?}"
: "${HOST_IP:?}"
: "${SSH_USER:?}"
: "${LETSENCRYPT_EMAIL:?}"
printf "DOMAIN=%s\nHOST_IP=%s\nSSH_USER=%s\nLETSENCRYPT_EMAIL=%s\n" \
  "$DOMAIN" "$HOST_IP" "$SSH_USER" "$LETSENCRYPT_EMAIL"

echo "👉 Проверяю, что DNS указывает на нужный IP:"
dns_ip="$(getent ahostsv4 "$DOMAIN" | awk '{print $1; exit}')"
echo "DNS говорит: $dns_ip"
echo "Ожидаем: $HOST_IP"
if [[ "$dns_ip" != "$HOST_IP" ]]; then
  echo "❌ DNS не совпадает"
  exit 1
fi

echo "👉 Проверяю SSH-доступ:"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${SSH_USER}@${HOST_IP}" "id && uname -a >/dev/null"
echo "✅ SSH доступен"

echo "👉 (Опционально) Открываю порты 80/443 на сервере (Ubuntu/Debian):"
ssh "${SSH_USER}@${HOST_IP}" 'which ufw >/dev/null 2>&1 && sudo ufw allow 80,443/tcp || true'
ssh "${SSH_USER}@${HOST_IP}" 'sudo ss -ltnp | egrep -w ":80|:443" || echo "Пока никто не слушает 80/443 — это нормально до старта прокси/приложения"'

echo "✅ Базовая готовность подтверждена"
