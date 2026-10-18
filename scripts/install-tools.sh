#!/usr/bin/env bash
# Instala as ferramentas no servidor do GitHub (rclone, age e o cliente do PostgreSQL).
# Só roda dentro do GitHub Actions; no seu computador você não precisa disto.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

kind="${1:?uso: install-tools.sh db|audio}"
trim_vars SUPABASE_DB_URL

apt_update() {
  for _ in 1 2 3; do
    if sudo apt-get update -qq; then return 0; fi
    sleep 5
  done
  die "apt-get update falhou 3 vezes"
}

if [ "$kind" = db ]; then
  # Descobre a versão do PostgreSQL do Supabase: o pg_dump precisa ser da mesma versão (ou mais nova).
  PG_MAJOR="$(psql -X -w -Atq "$SUPABASE_DB_URL" -c "select current_setting('server_version_num')::int/10000")" \
    || die "não consegui conectar ao banco (confira SUPABASE_DB_URL: usuário, senha e Session pooler)"
  [[ "$PG_MAJOR" =~ ^[0-9]+$ ]] || die "versão do PostgreSQL não reconhecida"
  log "Banco em PostgreSQL $PG_MAJOR"
  # Repositório oficial do PostgreSQL (instruções de postgresql.org/download/linux/ubuntu).
  sudo install -d /usr/share/postgresql-common/pgdg
  sudo curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc
  echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
    | sudo tee /etc/apt/sources.list.d/pgdg.list >/dev/null
  apt_update
  sudo apt-get install -y -qq "postgresql-client-$PG_MAJOR" age rclone
  if [ -n "${GITHUB_ENV:-}" ]; then echo "PG_MAJOR=$PG_MAJOR" >> "$GITHUB_ENV"; fi
else
  apt_update
  sudo apt-get install -y -qq postgresql-client rclone
fi
log "Ferramentas instaladas."
