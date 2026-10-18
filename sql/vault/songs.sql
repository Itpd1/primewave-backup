-- Músicas do pedido, SEM título nem nome de artista: só o que liga pagamento, reembolso e entrega.
SELECT id, project_id, status, created_at, master_versions_selected_at,
       master_versions_first_accessed_at, final_master_first_downloaded_at,
       revisions_used, revisions_total, refund_requested_at, refunded_at,
       stripe_refund_id, final_adjustment_requested_at
FROM songs ORDER BY created_at, id
