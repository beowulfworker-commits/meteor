#!/usr/bin/env bash
set -Eeuo pipefail

DOMAIN="${DOMAIN:-example.com}"
HOST_IP="${HOST_IP:-203.0.113.10}"
SSH_USER="${SSH_USER:-deploy}"
SSH_PORT="${SSH_PORT:-22}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-ops@example.com}"
SYSTEM_USER="${SYSTEM_USER:-$SSH_USER}"

mkdir -p \
  inventory \
  group_vars \
  host_vars \
  vars \
  playbooks \
  scripts \
  .github/workflows

cat > ansible.cfg <<'INI'
[defaults]
inventory = inventory/hosts.yml
interpreter_python = auto
stdout_callback = yaml
retry_files_enabled = False
timeout = 30
forks = 20
nocows = True
host_key_checking = False

[ssh_connection]
pipelining = True
INI

cat > requirements.txt <<'TXT'
ansible>=8,<11
ansible-lint>=24.2.0
yamllint>=1.35.1
TXT

cat > .yamllint.yml <<'YAML'
extends: default
rules:
  line-length:
    max: 140
    level: warning
  document-start:
    present: false
YAML

cat > .gitignore <<'TXT'
.vault_pass.txt
__pycache__/
*.retry
TXT

cat > inventory/hosts.yml <<EOF
all:
  children:
    prod:
      hosts:
        web1:
          ansible_host: $HOST_IP
          ansible_user: $SSH_USER
          ansible_port: $SSH_PORT
          ansible_python_interpreter: /usr/bin/python3
EOF

cat > group_vars/all.yml <<EOF
site_domain: "$DOMAIN"
site_timezone: "UTC"
system_user: "$SYSTEM_USER"
letsencrypt_email: "$LETSENCRYPT_EMAIL"
EOF

cat > host_vars/web1.yml <<EOF
public_ipv4: "$HOST_IP"
enable_firewall: true
EOF

cat > vars/secrets.vault.yml.example <<'YAML'
registry_password: "CHANGE_ME"
db_password: "CHANGE_ME"
cloudflare_api_token: "CHANGE_ME"
smtp_password: "CHANGE_ME"
YAML

cat > vars/.gitignore <<'TXT'
secrets.vault.yml
TXT

cat > playbooks/ping.yml <<'YAML'
- name: Connectivity ping
  hosts: prod
  gather_facts: false
  tasks:
    - name: Ensure we can reach the host
      ansible.builtin.ping:
YAML

cat > playbooks/smoke.yml <<'YAML'
- name: Smoke checks on prod host
  hosts: prod
  become: true
  gather_facts: true
  tasks:
    - name: Show kernel/uname
      ansible.builtin.command: uname -a
      register: uname_out
      changed_when: false

    - name: Python presence
      ansible.builtin.stat:
        path: /usr/bin/python3
      register: py

    - name: Assert python exists
      ansible.builtin.assert:
        that:
          - py.stat.exists
        fail_msg: "Python3 not found at /usr/bin/python3"

    - name: Check free disk on /
      ansible.builtin.command: df -h /
      register: disk
      changed_when: false

    - name: DNS resolves the site_domain (remote perspective)
      ansible.builtin.getent:
        database: hosts
        key: "{{ site_domain }}"
      register: dns

    - name: Assert DNS had a result
      ansible.builtin.assert:
        that:
          - dns.ansible_facts.getent_hosts is defined
          - dns.ansible_facts.getent_hosts | length > 0
        fail_msg: "DNS failed to resolve {{ site_domain }}"

    - name: Summary
      ansible.builtin.debug:
        msg:
          - "Domain: {{ site_domain }}"
          - "Kernel: {{ uname_out.stdout | default('n/a') }}"
          - "Disk: {{ (disk.stdout_lines | default([]))[:2] }}"
YAML

cat > scripts/check-run.sh <<'BASH'
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
BASH

chmod +x scripts/check-run.sh

cat > .github/workflows/check-run.yml <<'YAML'
name: check-run

on:
  push:
    branches: [ main ]
  pull_request:
  workflow_dispatch:

jobs:
  lint-and-check:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Python
        uses: actions/setup-python@v5
        with:
          python-version: '3.12'

      - name: Install Ansible toolchain
        run: |
          python -m pip install --upgrade pip
          pip install -r requirements.txt

      - name: Lint YAML
        run: yamllint .

      - name: Lint Ansible
        run: ansible-lint

      - name: Validate inventory
        run: ansible-inventory -i inventory/hosts.yml --list

      - name: Syntax check playbooks
        run: |
          ansible-playbook -i inventory/hosts.yml playbooks/ping.yml --syntax-check
          ansible-playbook -i inventory/hosts.yml playbooks/smoke.yml --syntax-check

      - name: Setup SSH agent (remote checks)
        if: ${{ secrets.SSH_PRIVATE_KEY != '' && secrets.TARGET_HOST != '' }}
        uses: webfactory/ssh-agent@v0.9.0
        with:
          ssh-private-key: ${{ secrets.SSH_PRIVATE_KEY }}

      - name: Add known host
        if: ${{ secrets.SSH_PRIVATE_KEY != '' && secrets.TARGET_HOST != '' }}
        run: |
          mkdir -p ~/.ssh
          ssh-keyscan -H "${{ secrets.TARGET_HOST }}" >> ~/.ssh/known_hosts

      - name: Prepare vault password (optional)
        if: ${{ secrets.ANSIBLE_VAULT_PASSWORD != '' }}
        run: |
          echo "${{ secrets.ANSIBLE_VAULT_PASSWORD }}" > .vault_pass.txt

      - name: Remote ping
        if: ${{ secrets.SSH_PRIVATE_KEY != '' && secrets.TARGET_HOST != '' }}
        run: ansible-playbook -i inventory/hosts.yml playbooks/ping.yml -v

      - name: Smoke check (with secrets if present)
        if: ${{ secrets.SSH_PRIVATE_KEY != '' && secrets.TARGET_HOST != '' }}
        run: |
          if [ -f vars/secrets.vault.yml ] && [ -s ./.vault_pass.txt ]; then
            ansible-playbook -i inventory/hosts.yml playbooks/smoke.yml \
              --vault-password-file .vault_pass.txt -v
          else
            ansible-playbook -i inventory/hosts.yml playbooks/smoke.yml \
              -e @vars/secrets.vault.yml.example -v
          fi
YAML

printf "\n== Done ==\n"
echo "Used configuration:"
echo "  DOMAIN=$DOMAIN"
echo "  HOST_IP=$HOST_IP"
echo "  SSH_USER=$SSH_USER"
echo "  SSH_PORT=$SSH_PORT"
echo "  LETSENCRYPT_EMAIL=$LETSENCRYPT_EMAIL"
echo "  SYSTEM_USER=$SYSTEM_USER"
echo
echo "Next steps:"
echo "  1) (опционально) Создай vars/secrets.vault.yml и зашифруй: ansible-vault encrypt vars/secrets.vault.yml"
echo "  2) Добавь секреты в GitHub: SSH_PRIVATE_KEY, TARGET_HOST, ANSIBLE_VAULT_PASSWORD"
echo "  3) Коммит и пуш:"
echo "     git add -A && git commit -m 'Bootstrap Ansible inventory, secrets placeholders and CI' && git push -u origin main"
