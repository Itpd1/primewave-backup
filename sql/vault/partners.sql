-- Dados financeiros e de contato dos parceiros. SEM o hash da senha do Balance Page.
SELECT id, name, category, website, referral_slug, landing_page_slug, balance_page_slug,
       paypal_email, contact_email, contact_phone, no_paypal_account,
       commission_tier, custom_commission_rate, active, created_at
FROM partners ORDER BY created_at, id
