-- Arquivos que ainda existem: só a prova técnica (hash, tamanho, formato). SEM caminho e SEM nome original.
SELECT id, song_id, type, created_at, scheduled_deletion_at, sha256_hash, file_size_bytes,
       mime_type, duration_seconds, sample_rate_hz, bit_depth
FROM files ORDER BY created_at, id
