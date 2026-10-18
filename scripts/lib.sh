#!/usr/bin/env bash
# Funções comuns dos scripts de backup (este arquivo só é "carregado" pelos outros).
# Regra de ouro: nada aqui imprime senha, chave ou endereço de acesso.

export LC_ALL=C
TODAY="${BACKUP_TODAY:-$(date -u +%F)}"   # BACKUP_TODAY só serve para testes
THIS_MONTH="${TODAY:0:7}"
SUMMARY_FILE="${SUMMARY_FILE:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/backup-summary.txt}"
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-20}"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

warn() {
  printf '[%s] AVISO: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2
  if [ -n "${GITHUB_ACTIONS:-}" ]; then printf '::warning::%s\n' "$*"; fi
}

# Resumo curto: aparece no log e vai no corpo do aviso para o Healthchecks.
# Só pode ter números e nomes de arquivos de backup; nunca dados de clientes.
summary() { printf '%s\n' "$*" | tee -a "$SUMMARY_FILE"; }

die() {
  printf 'ERRO: %s\n' "$*" >&2
  if [ -n "${GITHUB_ACTIONS:-}" ]; then printf '::error::%s\n' "$*"; fi
  printf 'ERRO: %s\n' "$*" >> "$SUMMARY_FILE"
  exit 1
}

# Se qualquer comando falhar sem mensagem própria, registra a linha.
trap 'printf "FALHA inesperada (linha %s de %s)\n" "$LINENO" "$(basename "$0")" >> "$SUMMARY_FILE"' ERR

# Tira espaços e quebras de linha de Secrets colados (erro comum de copiar e colar).
trim_vars() {
  local v
  for v in "$@"; do
    if [ -n "${!v:-}" ]; then export "$v=$(printf '%s' "${!v}" | tr -d '[:space:]')"; fi
  done
}

require_vars() {
  local v
  local -a missing=()
  for v in "$@"; do
    if [ -z "${!v:-}" ]; then missing+=("$v"); fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    die "faltam estes Secrets no GitHub: ${missing[*]}"
  fi
}

# A chave de criptografia que vai nos Secrets é a PÚBLICA (começa com age1).
check_age_key() {
  local k
  [ -n "${AGE_PUBLIC_KEY:-}" ] || die "falta o Secret AGE_PUBLIC_KEY"
  for k in $AGE_PUBLIC_KEY; do
    case "$k" in
      AGE-SECRET-KEY-*) die "AGE_PUBLIC_KEY contém uma chave PRIVADA. Coloque só a chave pública (começa com age1) e gere um novo par de chaves" ;;
      age1*) ;;
      *) die "AGE_PUBLIC_KEY inválida: ela deve começar com age1" ;;
    esac
  done
}

age_encrypt() { # $1 = arquivo de entrada, $2 = arquivo de saída
  local k
  local -a args=()
  for k in $AGE_PUBLIC_KEY; do args+=(-r "$k"); done
  age "${args[@]}" -o "$2" "$1"
}

# --- rclone: tudo configurado por variáveis, sem arquivo de senha no disco ---
RCLONE_FLAGS=(--retries 5 --low-level-retries 10 -q)

setup_rclone() { # $1 = backup | both
  export RCLONE_CONFIG=/dev/null
  export RCLONE_CONFIG_BACKUP_TYPE=s3
  export RCLONE_CONFIG_BACKUP_PROVIDER=Cloudflare
  export RCLONE_CONFIG_BACKUP_REGION=auto
  export RCLONE_CONFIG_BACKUP_ACCESS_KEY_ID="$BACKUP_R2_ACCESS_KEY_ID"
  export RCLONE_CONFIG_BACKUP_SECRET_ACCESS_KEY="$BACKUP_R2_SECRET_ACCESS_KEY"
  export RCLONE_CONFIG_BACKUP_ENDPOINT="${BACKUP_R2_ENDPOINT:-https://${BACKUP_R2_ACCOUNT_ID}.r2.cloudflarestorage.com}"
  export RCLONE_CONFIG_BACKUP_ACL=private
  export RCLONE_CONFIG_BACKUP_NO_CHECK_BUCKET=true
  if [ "${1:-backup}" = both ]; then
    export RCLONE_CONFIG_PRIMARY_TYPE=s3
    export RCLONE_CONFIG_PRIMARY_PROVIDER=Cloudflare
    export RCLONE_CONFIG_PRIMARY_REGION=auto
    export RCLONE_CONFIG_PRIMARY_ACCESS_KEY_ID="$PRIMARY_R2_ACCESS_KEY_ID"
    export RCLONE_CONFIG_PRIMARY_SECRET_ACCESS_KEY="$PRIMARY_R2_SECRET_ACCESS_KEY"
    export RCLONE_CONFIG_PRIMARY_ENDPOINT="${PRIMARY_R2_ENDPOINT:-https://${PRIMARY_R2_ACCOUNT_ID}.r2.cloudflarestorage.com}"
    export RCLONE_CONFIG_PRIMARY_ACL=private
    export RCLONE_CONFIG_PRIMARY_NO_CHECK_BUCKET=true
  fi
}

# Tamanho (bytes) de um arquivo no R2; vazio se não existe.
remote_size() { # $1 = remoto:bucket/pasta/arquivo
  local dir="${1%/*}" name="${1##*/}"
  rclone lsf --files-only --format s --include "$name" "$dir" 2>/dev/null | head -n 1 || true
}

# Envia e CONFIRMA que o tamanho no destino é igual ao do arquivo local.
upload_verified() { # $1 = arquivo local, $2 = destino
  local want got
  want="$(stat -c %s "$1")"
  rclone copyto "$1" "$2" "${RCLONE_FLAGS[@]}" || die "falha ao enviar $(basename "$1") ao R2 de backup"
  got="$(remote_size "$2")"
  [ "$got" = "$want" ] || die "tamanho diferente no R2 de backup para $(basename "$1") (local $want, remoto ${got:-nenhum})"
}

# Rotação por data no NOME do arquivo. Só mexe em arquivos com o nome no padrão
# (prefixo-AAAA-MM-DD.* ou prefixo-AAAA-MM.*). Nunca esvazia a pasta: sempre
# sobram pelo menos "minimo" arquivos. Nada fora de daily/ e monthly/ é tocado.
prune_group() { # <bucket> <pasta> <prefixo> <dia|mes> <manter> <minimo>
  local bucket="$1" folder="$2" prefix="$3" kind="$4" limit="$5" min_keep="$6"
  local base="BACKUP:$bucket/$folder" f stamp cutoff total=0
  local -a del=()
  if [ "$kind" = dia ]; then
    cutoff="$(date -u -d "$TODAY - $((limit - 1)) days" +%F)"
  else
    cutoff="$(date -u -d "${THIS_MONTH}-01 - $((limit - 1)) months" +%Y-%m)"
  fi
  while IFS= read -r f; do
    [[ "$f" == "$prefix"* ]] || continue
    if [ "$kind" = dia ]; then
      [[ "$f" =~ ^[a-z]+-([0-9]{4}-[0-9]{2}-[0-9]{2})\. ]] || continue
    else
      [[ "$f" =~ ^[a-z]+-([0-9]{4}-[0-9]{2})\. ]] || continue
    fi
    stamp="${BASH_REMATCH[1]}"
    total=$((total + 1))
    if [[ "$stamp" < "$cutoff" ]]; then del+=("$f"); fi
  done < <(rclone lsf --files-only "$base" 2>/dev/null || true)

  if [ "${#del[@]}" -eq 0 ]; then return 0; fi
  if [ $((total - ${#del[@]})) -lt "$min_keep" ]; then
    warn "rotação de $folder/$prefix* ignorada: sobrariam menos de $min_keep arquivos"
    return 0
  fi
  for f in "${del[@]}"; do
    rclone deletefile "$base/$f" "${RCLONE_FLAGS[@]}" || die "falha ao apagar $folder/$f"
  done
  log "rotação: ${#del[@]} arquivo(s) antigo(s) removido(s) de $folder/$prefix*"
}

# Cópia "mensal" feita no próprio R2 (sem baixar de novo): vale para o 1º dia do
# mês e também para a 1ª execução de um mês em que ainda não existe a cópia mensal.
monthly_copy() { # <bucket> <arquivo-diario> <arquivo-mensal>
  local bucket="$1" daily="$2" monthly="$3"
  if [ "${TODAY:8:2}" = "01" ] || [ -z "$(remote_size "BACKUP:$bucket/monthly/$monthly")" ]; then
    rclone copyto "BACKUP:$bucket/daily/$daily" "BACKUP:$bucket/monthly/$monthly" "${RCLONE_FLAGS[@]}" \
      || die "falha ao criar a cópia mensal $monthly"
    [ "$(remote_size "BACKUP:$bucket/monthly/$monthly")" = "$(remote_size "BACKUP:$bucket/daily/$daily")" ] \
      || die "cópia mensal $monthly com tamanho diferente do arquivo diário"
    log "cópia mensal criada: $monthly"
  fi
}
