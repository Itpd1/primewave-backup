-- Caminhos (chaves no R2) dos áudios que entram no backup: o áudio ORIGINAL enviado
-- pelo cliente e o FINAL MASTER, só de pedidos PAGOS. "Pago" tem a mesma definição do
-- site (lib/retention.ts, PROJECT_IS_PAID): data de pagamento preenchida OU status "paid".
-- Quando o site apaga um arquivo (prazo vencido, exclusão de conta), a linha some desta
-- lista e o backup move a cópia para a lixeira de 7 dias.
SELECT DISTINCT f.path
FROM files f
JOIN songs s ON s.id = f.song_id
JOIN projects p ON p.id = s.project_id
WHERE f.type IN ('ORIGINAL_UPLOAD', 'FINAL_MASTER')
  AND (p.paid_at IS NOT NULL OR p.payment_status = 'paid')
  AND f.path <> ''
ORDER BY f.path;
