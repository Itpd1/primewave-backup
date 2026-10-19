# PrimeWave Backup

Backup automático do banco (Supabase) e dos áudios de pedidos pagos (Cloudflare R2), numa conta Cloudflare separada. Roda sozinho no GitHub, todos os dias, e avisa por e-mail se algo falhar **ou se não rodar**.

> Este repositório precisa ser **PRIVADO**. Nunca coloque senhas, chaves ou arquivos de backup dentro dele: tudo que é segredo vai em **Settings > Secrets** do GitHub (passo 7).

## O que é guardado, onde e por quanto tempo

| O quê | Quando | Onde (R2 de backup) | Fica por |
|---|---|---|---|
| Banco inteiro (schema `public`), criptografado | todo dia, 03:17 (Brasília) | `primewave-backup-db` / `daily/` | 35 dias |
| Cópia mensal do banco | 1ª execução de cada mês | `primewave-backup-db` / `monthly/` | 13 meses |
| Cofre fiscal em CSV (pagamentos, reembolsos, comissões, saques, hashes de entrega, downloads, aceite dos Termos), criptografado | todo dia | `primewave-backup-db` / `daily/` e `monthly/` | 35 dias (diário) e **7 anos** (mensal) |
| Áudio original e Final Master **de pedidos pagos** | todo dia, 04:43 (Brasília) | `primewave-backup-audio` / `current/` | enquanto o site mantiver o arquivo |
| Áudio que o site apagou (prazo vencido, exclusão de conta) | no dia seguinte | `primewave-backup-audio` / `trash/` | 7 dias, depois some |

**Teste de restauração diário:** antes de terminar, o backup do banco é restaurado num banco temporário e as tabelas são comparadas. Se não bater, o aviso de falha dispara.

**Criptografia:** o banco e o cofre fiscal são criptografados com uma chave **pública** (que fica no GitHub). Só quem tem a chave **privada** (que fica com você, fora do GitHub) consegue abrir. Se alguém roubar os Secrets do GitHub, os arquivos continuam fechados.

**Fica de fora de propósito:** fotos de perfil, versões de escuta, anexos de revisão, áudio de uploads não pagos e de cadastro grátis, mensagens de chat, sessões de login.

---

## Passo a passo (uma vez só, cerca de 45 minutos)

### 1. Repositório privado
No GitHub: **New repository** > nome `primewave-backup` > **Private** > crie. Depois **Add file > Upload files**, arraste **todo o conteúdo** desta pasta (inclusive a pasta `.github`) e confirme com **Commit changes**. Ligue a verificação em duas etapas (2FA) na sua conta GitHub.

Opcional, mais seguro: **Settings > Actions > General > Allow `owner`, and select non-`owner`, actions** e marque só as ações do próprio GitHub.

### 2. Chave de criptografia (a mais importante)
1. Baixe o `age` para Windows em <https://github.com/FiloSottile/age/releases/latest> (arquivo `age-vX.Y.Z-windows-amd64.zip`) e extraia.
2. Abra o PowerShell **dentro da pasta extraída** e rode: `.\age-keygen.exe -o primewave-backup-key.txt`
3. Ele mostra `Public key: age1...`. Essa linha (só o `age1...`) é a chave **pública**: vai no Secret `AGE_PUBLIC_KEY`.
4. O arquivo `primewave-backup-key.txt` contém a chave **privada** (linha `AGE-SECRET-KEY-...`). Guarde **duas cópias**: no gerenciador de senhas e num pendrive guardado em outro lugar. **Nunca** no GitHub, nem no chat, nem por e-mail.

> Sem essa chave privada os backups do banco não abrem. Sem ela, o backup é inútil. Faça o teste do passo 9.

### 3. Usuário só de leitura no Supabase
No Supabase: **SQL Editor** > cole e rode (troque a senha por uma só com letras e números, 24 ou mais caracteres):

```sql
create role backup_reader with login password 'TROQUE_POR_UMA_SENHA_LONGA_SO_LETRAS_E_NUMEROS';
grant usage on schema public to backup_reader;
grant select on all tables in schema public to backup_reader;
grant select on all sequences in schema public to backup_reader;
alter default privileges in schema public grant select on tables to backup_reader;
alter default privileges in schema public grant select on sequences to backup_reader;
```

Depois: botão **Connect** do projeto > aba **Session pooler** > copie a URI (host termina em `pooler.supabase.com`, porta **5432**). Nela, troque o usuário `postgres.XXXX` por `backup_reader.XXXX` (mantenha o `.XXXX`) e coloque a senha nova. Esse é o valor do Secret `SUPABASE_DB_URL`.

Por que *Session pooler*: o GitHub só usa IPv4, e a conexão direta do Supabase é IPv6. A porta 6543 (Transaction pooler) **não** serve para backup.
Se o login com `backup_reader` der erro, use temporariamente a URI do usuário `postgres` e me avise.

### 4. Token do R2 principal (só leitura)
Na conta Cloudflare **do site**: **R2 > Manage R2 API Tokens > Create API token** > permissão **Object Read only** > bucket do áudio (o mesmo de `R2_AUDIO_BUCKET_NAME`) > Create. Copie o **Access Key ID** e o **Secret Access Key** (aparecem uma vez só). O **Account ID** aparece na página inicial do R2.

### 5. Token do R2 de backup
Na conta Cloudflare **do backup**: crie outro token com **Object Read & Write**, só para os buckets `primewave-backup-db` e `primewave-backup-audio`. Copie Access Key ID, Secret e Account ID.

### 6. Avisos por e-mail (Healthchecks.io, grátis)
1. Crie conta em <https://healthchecks.io> e um projeto.
2. **Add Check** > nome `PrimeWave backup banco` > **Period 1 day**, **Grace Time 5 hours** > Save. Copie a **Ping URL** (`https://hc-ping.com/...`).
3. Repita com o nome `PrimeWave backup audio`.
4. Em **Integrations > Email**, adicione os dois e-mails que devem receber os alertas e ligue os dois nos dois checks.

### 7. Cadastrar os Secrets no GitHub
Repositório > **Settings > Secrets and variables > Actions > New repository secret**. Um por um (o nome precisa ser exatamente este):

| Secret | O que colocar |
|---|---|
| `SUPABASE_DB_URL` | URI da Session pooler com o usuário `backup_reader` (passo 3) |
| `AGE_PUBLIC_KEY` | a chave pública `age1...` (passo 2) |
| `PRIMARY_R2_ACCOUNT_ID` | Account ID da conta Cloudflare do site |
| `PRIMARY_R2_ACCESS_KEY_ID` | Access Key ID do token só de leitura (passo 4) |
| `PRIMARY_R2_SECRET_ACCESS_KEY` | Secret do token só de leitura (passo 4) |
| `BACKUP_R2_ACCOUNT_ID` | Account ID da conta Cloudflare do backup |
| `BACKUP_R2_ACCESS_KEY_ID` | Access Key ID do token do backup (passo 5) |
| `BACKUP_R2_SECRET_ACCESS_KEY` | Secret do token do backup (passo 5) |
| `HC_DB_URL` | Ping URL do check `PrimeWave backup banco` |
| `HC_AUDIO_URL` | Ping URL do check `PrimeWave backup audio` |

Os nomes dos buckets estão nos arquivos da pasta `.github/workflows` (`primewave-audio`, `primewave-backup-db`, `primewave-backup-audio`). Se o bucket de áudio do site tiver outro nome, troque a linha `PRIMARY_R2_AUDIO_BUCKET` em `backup-audio.yml`.

### 8. Primeira execução
Aba **Actions** > **Backup diário - banco e registros fiscais** > **Run workflow**. Espere ficar verde (3 a 6 minutos). Depois o mesmo com **Backup diário - áudios de pedidos pagos**. Se ficar vermelho, a mensagem de erro diz qual Secret ou configuração está errada.

Confira: no Healthchecks os dois checks ficam verdes; no R2 de backup aparecem `daily/db-...`, `daily/fiscal-...` e `current/...`.

### 9. Teste da chave (não pule)
Baixe um arquivo `daily/db-AAAA-MM-DD.dump.age` (Cloudflare > R2 de backup > bucket > arquivo > Download) e abra com a chave privada, como em `RESTAURAR.md`. Se abrir, está tudo certo. Repita a cada 6 meses.

---

## Quando chegar um alerta

| Mensagem | O que significa e o que fazer |
|---|---|
| `faltam estes Secrets no GitHub: ...` | Cadastre o Secret citado (passo 7). |
| `não consegui conectar ao banco` | Confira `SUPABASE_DB_URL`: Session pooler, usuário `backup_reader.XXXX`, senha. |
| `teste de restauração ... não bate` | O arquivo do dia foi guardado, mas a restauração de teste divergiu. Abra o log no GitHub e me envie as linhas "tabela ...". |
| `ATENÇÃO: N áudio(s) pago(s) não estão no R2 principal (X com cópia ..., Y sem cópia ...)` | Um áudio que o banco ainda lista não existe mais no R2 do site. O log do GitHub separa em duas listas. **Com cópia:** restaure a partir de `current/` no backup (veja `RESTAURAR.md`). **Sem cópia em lugar nenhum:** investigue o pedido; se for algo sem o que recuperar (pedido de teste, por exemplo), escreva o caminho em `config/ausentes-conhecidos.txt` para o alerta parar de disparar por ele. |
| `... deixariam de constar no banco: nada foi movido` | Muitos arquivos sumiram do banco de uma vez. Se foi esperado (lote de exclusões), rode o workflow na mão marcando **Permitir exclusão em massa**. Se não foi, **não marque**: investigue primeiro. |
| `o banco devolveu 0 áudios pagos mas o backup tem N` | Provável erro de conexão ou de permissão. Nada foi alterado. |
| Healthchecks: "não rodou" | O GitHub não executou no horário. Veja a aba Actions (workflow desativado? repositório inativo? limite de minutos?) e rode na mão. |

Para guardar um arquivo do banco **sem prazo** (disputa, investigação), copie-o para uma pasta `hold/` no bucket `primewave-backup-db`: o sistema nunca mexe nela. Áudio sob bloqueio de exceção (legal hold) já fica protegido, porque o site não o apaga.

## Para o advogado (texto sobre "ciclo técnico" dos backups)

- Banco: cópia diária por 35 dias; cópia mensal por 13 meses.
- Cofre fiscal (sem nomes de arquivo, títulos nem mensagens): cópia mensal por 7 anos.
- Áudio de pedidos pagos: mesma duração do original no site, mais até 8 dias depois que o site o apaga.
- Tudo criptografado em trânsito e em repouso (banco e cofre com chave própria; áudio com a criptografia padrão do R2).

## Custos

GitHub Actions (repositório privado): usa cerca de 200 dos 2.000 minutos grátis por mês. Cloudflare R2: os primeiros 10 GB são grátis; depois, cerca de US$ 0,015 por GB por mês. Healthchecks.io: plano grátis.
