#!/usr/bin/env bash
set -Eeuo pipefail

python -m pip install --upgrade pip >/dev/null
pip install -r requirements.txt

yamllint .
ansible-lint
ansible-inventory -i inventory/hosts.yml --list >/dev/null

ansible-playbook -i inventory/hosts.yml playbooks/ping.yml --syntax-check
ansible-playbook -i inventory/hosts.yml playbooks/smoke.yml --syntax-check

echo
echo "=== Remote run ==="
ansible-playbook -i inventory/hosts.yml playbooks/ping.yml -v || true
if [ -f vars/secrets.vault.yml ] && [ -n "${ANSIBLE_VAULT_PASSWORD:-}" ]; then
  printf "%s" "$ANSIBLE_VAULT_PASSWORD" > .vault_pass.txt
  ansible-playbook -i inventory/hosts.yml playbooks/smoke.yml \
    --vault-password-file .vault_pass.txt -v || true
else
  ansible-playbook -i inventory/hosts.yml playbooks/smoke.yml \
    -e @vars/secrets.vault.yml.example -v || true
fi
