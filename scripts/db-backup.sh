#!/usr/bin/env bash
# Backup diário do banco (Supabase Postgres).
#
# O que faz, nesta ordem:
#   1. gera o dump do schema "public" (tudo do site e do login);
#   2. confere que o dump é legível;
#   3. criptografa com a chave PÚBLICA (só você, com a chave privada, abre);
#   4. envia ao R2 de backup e confere o tamanho;
#   5. guarda a cópia mensal e apaga o que passou do prazo;
#   6. TESTE DE RESTAURAÇÃO: restaura o dump num banco temporário e compara
#      as tabelas. Se falhar, o aviso de falha é disparado.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

trim_vars SUPABASE_DB_URL BACKUP_R2_ACCOUNT_ID BACKUP_R2_ACCESS_KEY_ID BACKUP_R2_SECRET_ACCESS_KEY BACKUP_R2_DB_BUCKET
require_vars SUPABASE_DB_URL BACKUP_R2_ACCOUNT_ID BACKUP_R2_ACCESS_KEY_ID BACKUP_R2_SECRET_ACCESS_KEY
check_age_key
DB_BUCKET="${BACKUP_R2_DB_BUCKET:-primewave-backup-db}"
setup_rclone backup

PSQL=(psql -X -w -Atq -v ON_ERROR_STOP=1)
PG_MAJOR="${PG_MAJOR:-$("${PSQL[@]}" "$SUPABASE_DB_URL" -c "select current_setting('server_version_num')::int/10000" 2>/dev/null)}" \
  || die "não consegui conectar ao banco (confira SUPABASE_DB_URL: usuário, senha e a opção Session pooler)"
PGBIN="${PGBIN:-/usr/lib/postgresql/$PG_MAJOR/bin}"
[ -x "$PGBIN/pg_dump" ] || die "pg_dump $PG_MAJOR não encontrado em $PGBIN"

WORK="$(mktemp -d)"
DUMP="$WORK/db.dump"
RT_CONTAINER=""
cleanup() {
  if [ -n "$RT_CONTAINER" ]; then docker rm -f "$RT_CONTAINER" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

# Lista "tabela|linhas" de todas as tabelas do schema public (uma conexão só).
table_counts() { # $1 = endereço do banco
  "${PSQL[@]}" "$1" <<'SQL'
select format('select %L, count(*) from public.%I', tablename, tablename)
from pg_tables where schemaname = 'public' order by tablename
\gexec
SQL
}

# ---------------------------------------------------------------- 1 e 2: dump
log "Gerando o dump (PostgreSQL $PG_MAJOR)..."
# Contagens ANTES e DEPOIS do dump: o site continua gravando durante o backup, então o
# dump fica entre as duas medições e o teste de restauração usa essa faixa.
table_counts "$SUPABASE_DB_URL" > "$WORK/cnt_before.txt"
"$PGBIN/pg_dump" --dbname="$SUPABASE_DB_URL" --format=custom --compress=6 \
  --schema=public --no-owner --no-privileges \
  --exclude-table-data='public.session' --exclude-table-data='public.verification' \
  --file="$DUMP" || die "o pg_dump falhou"
DUMP_BYTES="$(stat -c %s "$DUMP")"
[ "$DUMP_BYTES" -gt 2048 ] || die "dump pequeno demais ($DUMP_BYTES bytes): backup não enviado"
"$PGBIN/pg_restore" --list "$DUMP" > "$WORK/toc.txt" || die "dump ilegível (pg_restore --list falhou)"
TABLES_IN_DUMP="$(grep -c ' TABLE public ' "$WORK/toc.txt" || true)"
[ "$TABLES_IN_DUMP" -gt 0 ] || die "o dump não contém nenhuma tabela"
table_counts "$SUPABASE_DB_URL" > "$WORK/cnt_after.txt"

# ---------------------------------------------------------------- 3 e 4: criptografar e enviar
DAILY_NAME="db-$TODAY.dump.age"
MONTHLY_NAME="db-$THIS_MONTH.dump.age"
age_encrypt "$DUMP" "$WORK/$DAILY_NAME"
upload_verified "$WORK/$DAILY_NAME" "BACKUP:$DB_BUCKET/daily/$DAILY_NAME"
log "Dump enviado: daily/$DAILY_NAME ($(stat -c %s "$WORK/$DAILY_NAME") bytes criptografados)"

# ---------------------------------------------------------------- 5: mensal e rotação
monthly_copy "$DB_BUCKET" "$DAILY_NAME" "$MONTHLY_NAME"
prune_group "$DB_BUCKET" daily db dia 35 7
prune_group "$DB_BUCKET" monthly db mes 13 3

# ---------------------------------------------------------------- 6: teste de restauração
start_restore_db() {
  if [ -n "${RESTORE_TEST_URL:-}" ]; then RT_URL="$RESTORE_TEST_URL"; return 0; fi
  command -v docker >/dev/null || die "docker não encontrado para o teste de restauração"
  RT_CONTAINER="pw-restore-test-$$"
  docker run -d --name "$RT_CONTAINER" -e POSTGRES_PASSWORD=restoretest \
    -p 127.0.0.1:55432:5432 "postgres:$PG_MAJOR" >/dev/null || die "não consegui iniciar o banco temporário"
  RT_URL="postgresql://postgres:restoretest@127.0.0.1:55432/postgres"
  for _ in $(seq 1 90); do
    if "${PSQL[@]}" "$RT_URL" -c 'select 1' >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  die "o banco temporário não ficou pronto em 90 segundos"
}

log "Teste de restauração..."
start_restore_db
# --clean --if-exists: o dump traz "CREATE SCHEMA public" e o banco temporário já tem esse schema.
if ! "$PGBIN/pg_restore" --dbname="$RT_URL" --clean --if-exists --no-owner --no-privileges "$DUMP" 2> "$WORK/restore.err"; then
  head -n 5 "$WORK/restore.err" >&2 || true
  die "a restauração do dump no banco temporário deu erro (o arquivo criptografado já está guardado)"
fi
table_counts "$RT_URL" > "$WORK/rst_counts.txt"

declare -A BEF=() AFT=() RST=()
while IFS='|' read -r t n; do [ -z "$t" ] || BEF[$t]="$n"; done < "$WORK/cnt_before.txt"
while IFS='|' read -r t n; do [ -z "$t" ] || AFT[$t]="$n"; done < "$WORK/cnt_after.txt"
while IFS='|' read -r t n; do [ -z "$t" ] || RST[$t]="$n"; done < "$WORK/rst_counts.txt"
BAD=0
for t in "${!AFT[@]}"; do
  if [ -z "${RST[$t]+x}" ]; then echo "tabela ausente na restauração: $t" >&2; BAD=1; continue; fi
  case "$t" in session|verification) continue ;; esac   # dados desligados de propósito
  a="${AFT[$t]}"; b="${BEF[$t]:-$a}"; r="${RST[$t]}"
  lo=$((b < a ? b : a)); hi=$((b > a ? b : a))
  tol=$((hi / 50)); [ "$tol" -ge 2 ] || tol=2           # tolerância para o que o site gravou durante o backup
  if { [ "$lo" -gt 0 ] && [ "$r" -eq 0 ]; } || [ "$r" -lt $((lo - tol)) ] || [ "$r" -gt $((hi + tol)) ]; then
    echo "tabela $t: origem entre $lo e $hi linhas, restaurado $r" >&2; BAD=1
  fi
done
for t in "${!RST[@]}"; do
  if [ -z "${AFT[$t]+x}" ]; then echo "tabela extra na restauração: $t" >&2; BAD=1; fi
done
[ "$BAD" -eq 0 ] || die "teste de restauração: tabelas ou contagens não batem (detalhes no log)"

summary "banco: OK | $TABLES_IN_DUMP tabelas | dump ${DUMP_BYTES} bytes | restauração testada | arquivo daily/$DAILY_NAME"
