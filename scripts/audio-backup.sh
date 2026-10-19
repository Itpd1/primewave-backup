#!/usr/bin/env bash
# Backup dos áudios: copia do R2 principal para o R2 de backup SÓ os áudios de
# pedidos pagos (áudio original do cliente + Final Master).
#
# A lista do que proteger vem do BANCO (sql/audio-paid-paths.sql), não do R2:
#   - se um arquivo sumir do R2 principal por engano, a cópia continua no backup
#     (o banco ainda o lista) e o aviso de falha dispara;
#   - quando o site apaga um arquivo de propósito (prazo vencido, exclusão de
#     conta), a linha some do banco; a cópia vai para a lixeira por 7 dias e
#     depois é apagada. Arquivos sob bloqueio de exceção (legal hold) o site não
#     apaga, então continuam aqui também.
#
# O token do R2 principal é SÓ DE LEITURA: este script nunca altera o R2 principal.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
SQL_DIR="${SQL_DIR:-$HERE/../sql}"

trim_vars SUPABASE_DB_URL PRIMARY_R2_ACCOUNT_ID PRIMARY_R2_ACCESS_KEY_ID PRIMARY_R2_SECRET_ACCESS_KEY \
  PRIMARY_R2_AUDIO_BUCKET BACKUP_R2_ACCOUNT_ID BACKUP_R2_ACCESS_KEY_ID BACKUP_R2_SECRET_ACCESS_KEY BACKUP_R2_AUDIO_BUCKET
require_vars SUPABASE_DB_URL PRIMARY_R2_ACCOUNT_ID PRIMARY_R2_ACCESS_KEY_ID PRIMARY_R2_SECRET_ACCESS_KEY \
  BACKUP_R2_ACCOUNT_ID BACKUP_R2_ACCESS_KEY_ID BACKUP_R2_SECRET_ACCESS_KEY
SRC_BUCKET="${PRIMARY_R2_AUDIO_BUCKET:-primewave-audio}"
DST_BUCKET="${BACKUP_R2_AUDIO_BUCKET:-primewave-backup-audio}"
TRASH_DAYS=7
setup_rclone both

SRC="PRIMARY:$SRC_BUCKET"
LIVE="BACKUP:$DST_BUCKET/current"
TRASH="BACKUP:$DST_BUCKET/trash"
WORK="$(mktemp -d)"

lines() { if [ -s "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

# rclone lsf devolve 3 quando a pasta ainda não existe (1ª execução): vale como lista vazia.
list_keys() { # $1 = remoto, $2 = arquivo de saída
  local rc=0
  rclone lsf -R --files-only "$1" 2> "$WORK/lsf.err" | LC_ALL=C sort > "$2" || rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then head -n 5 "$WORK/lsf.err" >&2 || true; return 1; fi
  return 0
}

# ---------------------------------------------------------------- listas
log "Lendo do banco a lista de áudios pagos..."
psql -X -w -Atq -v ON_ERROR_STOP=1 "$SUPABASE_DB_URL" -f "$SQL_DIR/audio-paid-paths.sql" > "$WORK/paid.raw" \
  || die "não consegui ler a lista de áudios pagos no banco (confira SUPABASE_DB_URL)"
{ grep -v '^$' "$WORK/paid.raw" || true; } | LC_ALL=C sort -u > "$WORK/paid.txt"
list_keys "$SRC" "$WORK/primary.txt" || die "não consegui listar o bucket de áudio do R2 principal (token de leitura?)"
list_keys "$LIVE" "$WORK/live.txt" || die "não consegui listar o bucket do R2 de backup"

comm -12 "$WORK/paid.txt" "$WORK/primary.txt" > "$WORK/present.txt"   # pagos que existem no R2 principal
comm -23 "$WORK/paid.txt" "$WORK/primary.txt" > "$WORK/missing.txt"   # pagos que NÃO estão no R2 principal
comm -23 "$WORK/present.txt" "$WORK/live.txt" > "$WORK/new.txt"       # pagos ainda sem cópia
comm -13 "$WORK/paid.txt" "$WORK/live.txt" > "$WORK/trash.txt"        # cópias que o site já apagou

# Dos pagos que sumiram do R2 principal: alguns têm cópia no backup (recuperáveis) e outros
# não têm cópia em lugar nenhum. Estes últimos podem ser reconhecidos de propósito em
# config/ausentes-conhecidos.txt (ex.: pedidos de teste); o aviso de falha dispara para o resto.
comm -12 "$WORK/missing.txt" "$WORK/live.txt" > "$WORK/missing_copy.txt"
comm -23 "$WORK/missing.txt" "$WORK/live.txt" > "$WORK/missing_nocopy.txt"
KNOWN_FILE="${KNOWN_MISSING_FILE:-$HERE/../config/ausentes-conhecidos.txt}"
if [ -f "$KNOWN_FILE" ]; then
  { sed 's/\r$//; s/^[[:space:]]*//; s/[[:space:]]*$//' "$KNOWN_FILE" | grep -v '^#' | grep -v '^$' || true; } \
    | LC_ALL=C sort -u > "$WORK/known.txt"
else
  : > "$WORK/known.txt"
fi
comm -12 "$WORK/missing_nocopy.txt" "$WORK/known.txt" > "$WORK/missing_known.txt"
comm -23 "$WORK/missing_nocopy.txt" "$WORK/known.txt" > "$WORK/missing_lost.txt"

N_PAID="$(lines "$WORK/paid.txt")"; N_PRIMARY="$(lines "$WORK/primary.txt")"; N_LIVE="$(lines "$WORK/live.txt")"
N_MISSING="$(lines "$WORK/missing.txt")"; N_NEW="$(lines "$WORK/new.txt")"; N_TRASH="$(lines "$WORK/trash.txt")"
N_MISS_COPY="$(lines "$WORK/missing_copy.txt")"; N_MISS_LOST="$(lines "$WORK/missing_lost.txt")"; N_MISS_KNOWN="$(lines "$WORK/missing_known.txt")"

# ---------------------------------------------------------------- travas de segurança
# Para liberar de propósito: rode o workflow na mão marcando "Permitir exclusão em massa".
OVERRIDE_HINT="Se for esperado, rode o workflow na mão marcando 'Permitir exclusão em massa'."
# Uma lista vazia com backup cheio quase sempre é erro de consulta, não "todo mundo foi apagado".
if [ "$N_PAID" -eq 0 ] && [ "$N_LIVE" -gt 0 ] && [ "${ALLOW_MASS_TRASH:-}" != true ]; then
  die "o banco devolveu 0 áudios pagos mas o backup tem $N_LIVE: nada foi alterado (confira a conexão com o banco). $OVERRIDE_HINT"
fi
# Mais de 20% do backup (e mais de 10 arquivos) saindo de uma vez também exige olhar com calma.
if [ "$N_TRASH" -gt 10 ] && [ $((N_TRASH * 5)) -gt "$N_LIVE" ] && [ "${ALLOW_MASS_TRASH:-}" != true ]; then
  die "$N_TRASH de $N_LIVE arquivos do backup deixariam de constar no banco: nada foi movido (confira antes). $OVERRIDE_HINT"
fi

# ---------------------------------------------------------------- copiar o que é novo
# Passa a lista inteira dos pagos: o rclone pula o que já está igual (mesmo tamanho) e
# atualiza o que mudou. Só os "novos" entram na contagem do resumo.
if [ "$(lines "$WORK/present.txt")" -gt 0 ]; then
  log "Copiando/atualizando o backup ($N_NEW novo(s))..."
  # --disable copy: as duas contas Cloudflare são diferentes e o R2 não faz cópia direta entre
  # contas (erro 501). Assim o rclone baixa e reenvia o arquivo, sem tentar a cópia direta antes.
  rclone copy "$SRC" "$LIVE" --files-from-raw "$WORK/present.txt" --size-only --transfers 4 --disable copy \
    "${RCLONE_FLAGS[@]}" || die "falha ao copiar arquivos para o backup"
fi
# Confere que TODO áudio pago presente no R2 principal tem a cópia, com o mesmo tamanho.
if [ "$(lines "$WORK/present.txt")" -gt 0 ]; then
  rclone check "$SRC" "$LIVE" --files-from-raw "$WORK/present.txt" --size-only --one-way \
    "${RCLONE_FLAGS[@]}" || die "a conferência de tamanho entre o R2 principal e o backup falhou"
fi

# ---------------------------------------------------------------- lixeira de 7 dias
if [ "$N_TRASH" -gt 0 ]; then
  log "Movendo $N_TRASH cópia(s) de arquivos apagados pelo site para a lixeira..."
  rclone move "$LIVE" "$TRASH/$TODAY" --files-from-raw "$WORK/trash.txt" \
    "${RCLONE_FLAGS[@]}" || die "falha ao mover cópias para a lixeira"
fi
N_PURGED=0
CUTOFF="$(date -u -d "$TODAY - $TRASH_DAYS days" +%F)"
while IFS= read -r d; do
  if [[ "$d" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})/$ ]] && [[ "${BASH_REMATCH[1]}" < "$CUTOFF" ]]; then
    rclone delete "$TRASH/${BASH_REMATCH[1]}" "${RCLONE_FLAGS[@]}" || die "falha ao esvaziar a lixeira de ${BASH_REMATCH[1]}"
    N_PURGED=$((N_PURGED + 1))
  fi
done < <(rclone lsf --dirs-only "$TRASH" 2>/dev/null || true)

# ---------------------------------------------------------------- resultado
summary "áudio: pagos no banco $N_PAID | no R2 principal $N_PRIMARY (total do bucket) | novos copiados $N_NEW | movidos p/ lixeira $N_TRASH | lixeiras antigas esvaziadas $N_PURGED | ausentes do R2 principal $N_MISSING (com cópia no backup $N_MISS_COPY, sem cópia $((N_MISS_LOST + N_MISS_KNOWN)), destes reconhecidos $N_MISS_KNOWN)"
if [ "$N_MISS_KNOWN" -gt 0 ]; then
  warn "$N_MISS_KNOWN áudio(s) pago(s) ausentes do R2 principal e sem cópia, reconhecidos em config/ausentes-conhecidos.txt:"
  sed 's/^/  - /' "$WORK/missing_known.txt" >&2
fi
if [ "$N_MISS_COPY" -gt 0 ]; then
  log "Áudios pagos que o banco lista, o R2 principal NÃO tem e o backup TEM (restaure a partir de current/):"
  sed 's/^/  - /' "$WORK/missing_copy.txt"
fi
if [ "$N_MISS_LOST" -gt 0 ]; then
  log "Áudios pagos que o banco lista e que NÃO existem no R2 principal NEM no backup (perdidos):"
  sed 's/^/  - /' "$WORK/missing_lost.txt"
fi
if [ $((N_MISS_COPY + N_MISS_LOST)) -gt 0 ]; then
  die "ATENÇÃO: $((N_MISS_COPY + N_MISS_LOST)) áudio(s) pago(s) não estão no R2 principal ($N_MISS_COPY com cópia em current/ no backup, $N_MISS_LOST sem cópia em lugar nenhum). Lista no log do GitHub"
fi
