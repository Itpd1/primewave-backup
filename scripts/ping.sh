#!/usr/bin/env bash
# Avisa o Healthchecks.io: start | success | fail
#   - se o aviso de SUCESSO não chegar no prazo, o Healthchecks manda e-mail ("não rodou");
#   - se chegar o aviso de FALHA, manda e-mail na hora.
# O corpo do aviso é o resumo da execução (números e nomes de arquivos de backup; sem dados de clientes).
set -uo pipefail
action="${1:?uso: ping.sh start|success|fail}"
SUMMARY_FILE="${SUMMARY_FILE:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/backup-summary.txt}"

url="$(printf '%s' "${HC_URL:-}" | tr -d '[:space:]')"
if [ -z "$url" ]; then
  echo "AVISO: o endereço do Healthchecks não está configurado; aviso '$action' não enviado."
  exit 0
fi
case "$url" in https://hc-ping.com/*) ;; *) echo "AVISO: endereço do Healthchecks inválido; aviso '$action' não enviado."; exit 0 ;; esac

case "$action" in
  start) suffix="/start" ;;
  success) suffix="" ;;
  fail) suffix="/fail" ;;
  *) echo "uso: ping.sh start|success|fail"; exit 1 ;;
esac

body=""
if [ "$action" != start ] && [ -f "$SUMMARY_FILE" ]; then body="$(tail -c 3000 "$SUMMARY_FILE")"; fi
if [ "$action" = fail ] && [ -z "$body" ]; then body="O backup falhou. Veja o log da execução no GitHub (aba Actions)."; fi

if curl -fsS -m 15 --retry 5 --retry-delay 3 --retry-all-errors --data-raw "$body" "${url%/}${suffix}" >/dev/null; then
  echo "Aviso '$action' enviado ao Healthchecks."
else
  echo "::warning::Não consegui enviar o aviso '$action' ao Healthchecks."
fi
exit 0
