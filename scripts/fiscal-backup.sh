#!/usr/bin/env bash
# Cofre de 7 anos: pagamentos, reembolsos, comissões e saques de parceiros,
# provas de entrega (hashes), registro de downloads e aceite dos Termos.
#
# Sai em CSV (abre em qualquer planilha daqui a 7 anos, sem precisar do
# PostgreSQL), dentro de um .tar criptografado. Uma exportação por dia
# (daily/, guardadas por 35 dias) e uma por mês (monthly/, guardadas por
# 7 anos). Cada exportação já contém TUDO que existe no banco naquele dia.
#
# Fica de fora de propósito: nomes de arquivo, títulos de músicas, mensagens,
# senhas e dados de perfil. As consultas estão em sql/vault/*.sql.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
SQL_DIR="${SQL_DIR:-$HERE/../sql}"

trim_vars SUPABASE_DB_URL BACKUP_R2_ACCOUNT_ID BACKUP_R2_ACCESS_KEY_ID BACKUP_R2_SECRET_ACCESS_KEY BACKUP_R2_DB_BUCKET
require_vars SUPABASE_DB_URL BACKUP_R2_ACCOUNT_ID BACKUP_R2_ACCESS_KEY_ID BACKUP_R2_SECRET_ACCESS_KEY
check_age_key
DB_BUCKET="${BACKUP_R2_DB_BUCKET:-primewave-backup-db}"
setup_rclone backup

WORK="$(mktemp -d)"
OUT="$WORK/vault"
mkdir -p "$OUT"

# Um único roteiro do psql, numa transação só: todas as tabelas saem do MESMO instante.
SCRIPT="$WORK/vault.psql"
shopt -s nullglob
QUERIES=("$SQL_DIR"/vault/*.sql)
shopt -u nullglob
[ "${#QUERIES[@]}" -gt 0 ] || die "nenhuma consulta encontrada em sql/vault"
{
  echo "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;"
  for f in "${QUERIES[@]}"; do
    name="$(basename "$f" .sql)"
    q="$(grep -v '^[[:space:]]*--' "$f" | tr '\n' ' ' | sed -E 's/[[:space:]]+$//; s/;$//')"
    printf '\\copy (%s) TO '"'"'%s/%s.csv'"'"' WITH (FORMAT csv, HEADER true)\n' "$q" "$OUT" "$name"
  done
  echo "COMMIT;"
} > "$SCRIPT"

log "Exportando ${#QUERIES[@]} tabelas fiscais..."
psql -X -w -q -v ON_ERROR_STOP=1 "$SUPABASE_DB_URL" -f "$SCRIPT" >/dev/null \
  || die "a exportação fiscal falhou (alguma consulta de sql/vault não bate com o banco)"

TOTAL_ROWS=0
{
  echo "PrimeWave - registros fiscais e provas de entrega"
  echo "Exportado em $TODAY (UTC). Cada arquivo .csv é uma tabela do banco."
  echo
} > "$OUT/LEIAME.txt"
for f in "${QUERIES[@]}"; do
  name="$(basename "$f" .sql)"
  [ -s "$OUT/$name.csv" ] || die "$name.csv saiu vazio (nem o cabeçalho foi gerado)"
  rows="$(python3 -c 'import csv,sys; print(sum(1 for _ in csv.reader(open(sys.argv[1], newline="", encoding="utf-8")))-1)' "$OUT/$name.csv")"
  TOTAL_ROWS=$((TOTAL_ROWS + rows))
  printf '%s.csv: %s linhas\n' "$name" "$rows" >> "$OUT/LEIAME.txt"
done
(cd "$OUT" && sha256sum ./*.csv > SHA256SUMS.txt)
tar -C "$OUT" -cf "$WORK/vault.tar" .

DAILY_NAME="fiscal-$TODAY.tar.age"
MONTHLY_NAME="fiscal-$THIS_MONTH.tar.age"
age_encrypt "$WORK/vault.tar" "$WORK/$DAILY_NAME"
upload_verified "$WORK/$DAILY_NAME" "BACKUP:$DB_BUCKET/daily/$DAILY_NAME"
monthly_copy "$DB_BUCKET" "$DAILY_NAME" "$MONTHLY_NAME"
prune_group "$DB_BUCKET" daily fiscal dia 35 7
prune_group "$DB_BUCKET" monthly fiscal mes 85 3

summary "fiscal: OK | ${#QUERIES[@]} tabelas, $TOTAL_ROWS linhas | arquivo daily/$DAILY_NAME"
