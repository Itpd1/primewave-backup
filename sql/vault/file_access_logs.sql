-- Quem baixou qual arquivo e quando (o IP é zerado pelo site depois de 12 meses).
SELECT * FROM file_access_logs ORDER BY accessed_at, id
