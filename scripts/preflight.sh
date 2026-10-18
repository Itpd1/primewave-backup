#!/usr/bin/env bash
# Primeira etapa de cada backup: confere se todos os Secrets existem e têm cara de certos.
# Se faltar algo, o erro já diz o NOME do Secret que falta (nunca o valor).
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

kind="${1:?uso: preflight.sh db|audio}"
: > "$SUMMARY_FILE"   # começa um resumo novo para esta execução

trim_vars SUPABASE_DB_URL HC_URL BACKUP_R2_ACCOUNT_ID BACKUP_R2_ACCESS_KEY_ID BACKUP_R2_SECRET_ACCESS_KEY \
  PRIMARY_R2_ACCOUNT_ID PRIMARY_R2_ACCESS_KEY_ID PRIMARY_R2_SECRET_ACCESS_KEY

case "$kind" in
  db)
    require_vars SUPABASE_DB_URL AGE_PUBLIC_KEY BACKUP_R2_ACCOUNT_ID BACKUP_R2_ACCESS_KEY_ID BACKUP_R2_SECRET_ACCESS_KEY HC_URL
    check_age_key
    ;;
  audio)
    require_vars SUPABASE_DB_URL PRIMARY_R2_ACCOUNT_ID PRIMARY_R2_ACCESS_KEY_ID PRIMARY_R2_SECRET_ACCESS_KEY \
      BACKUP_R2_ACCOUNT_ID BACKUP_R2_ACCESS_KEY_ID BACKUP_R2_SECRET_ACCESS_KEY HC_URL
    ;;
  *) die "preflight: tipo desconhecido '$kind'" ;;
esac

case "$SUPABASE_DB_URL" in
  postgres://*|postgresql://*) ;;
  *) die "SUPABASE_DB_URL deve começar com postgresql://" ;;
esac
case "$SUPABASE_DB_URL" in
  *:6543/*) die "SUPABASE_DB_URL usa a porta 6543 (Transaction pooler), que não serve para backup. Use a Session pooler (porta 5432)" ;;
esac
case "$SUPABASE_DB_URL" in
  *@db.*.supabase.co*) warn "SUPABASE_DB_URL parece ser a conexão direta (só IPv6). O GitHub só tem IPv4: se der erro de conexão, use a Session pooler" ;;
esac
case "$HC_URL" in
  https://hc-ping.com/*) ;;
  *) die "o endereço do Healthchecks deve começar com https://hc-ping.com/" ;;
esac

log "Configuração conferida."
