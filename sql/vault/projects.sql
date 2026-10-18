-- Pagamentos: um projeto = um pagamento (valor em centavos, moeda, Stripe, dados de cobrança).
SELECT * FROM projects ORDER BY submitted_at, id
