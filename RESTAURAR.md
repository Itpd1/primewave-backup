# Como restaurar

Você precisa de: a **chave privada** (`primewave-backup-key.txt`), o programa `age` (mesmo download do README) e, para o banco, o `pg_restore` (vem com o PostgreSQL; use a mesma versão do Supabase ou mais nova).

Baixar um arquivo do backup: Cloudflare (conta de backup) > R2 > bucket > pasta > arquivo > **Download**.

## Banco de dados

```powershell
# 1. abrir o arquivo criptografado
.\age.exe -d -i primewave-backup-key.txt -o db.dump db-AAAA-MM-DD.dump.age

# 2. restaurar num banco VAZIO (novo projeto do Supabase ou PostgreSQL local)
pg_restore --clean --if-exists --no-owner --no-privileges --dbname="postgresql://USUARIO:SENHA@HOST:5432/postgres" db.dump
```

- Volta tudo do schema `public` (pedidos, músicas, parceiros, login do Better Auth...). Podem aparecer 1 ou 2 avisos sobre o schema `public` já existir: são normais, pode ignorar.
- As tabelas `session` e `verification` voltam **vazias** de propósito: todo mundo precisa entrar de novo.
- Depois, aponte `DATABASE_URL` e `DIRECT_URL` do site para o banco restaurado.

## Cofre fiscal (7 anos)

```powershell
.\age.exe -d -i primewave-backup-key.txt -o fiscal.tar fiscal-AAAA-MM.tar.age
tar -xf fiscal.tar
```

Saem arquivos `.csv` (abrem no Excel ou LibreOffice), mais `LEIAME.txt` (linhas por tabela) e `SHA256SUMS.txt` (para conferir que nada foi alterado).

## Áudio

Os arquivos ficam sem criptografia extra no bucket `primewave-backup-audio`, na pasta `current/`, com o **mesmo caminho** que têm no R2 do site (ex.: `current/orders/abc/original.wav`).

- Poucos arquivos: baixe pelo painel da Cloudflare e envie de volta ao bucket do site com o mesmo caminho (sem o `current/`).
- Muitos arquivos: com o `rclone` configurado para as duas contas:
  `rclone copy backup:primewave-backup-audio/current site:NOME-DO-BUCKET-DE-AUDIO --progress`
- Algo apagado há menos de 7 dias pelo site está em `trash/AAAA-MM-DD/` (mesmo caminho, depois da data).
