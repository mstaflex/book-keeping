# Instructions for Claude

This repository is **public**. It contains the code for an n8n-based bookkeeping
setup, but none of the data or infrastructure of the instance it runs on. Keep
it that way: everything below applies to every change, commit, commit message,
PR text and comment you write here.

## 1. Never commit

- **Secrets:** passwords, API keys, OAuth client IDs and secrets, Etsy
  keystrings and shared secrets, Notion integration secrets, SMTP credentials,
  tokens of any kind, `.env` contents, files from the `secrets_data` volume.
- **Infrastructure details:** the domain or URL of the running n8n instance,
  server hostnames and IPs, the hosting or e-mail provider, deploy paths that
  reveal either. This includes OAuth redirect URLs, which contain the n8n domain.
- **Personal and business data of the operator:** real names, e-mail addresses,
  postal addresses, IBAN, tax number, own VAT ID, shop name and shop domain.
- **Instance IDs:** Notion database or page IDs, Etsy shop ID, real n8n
  credential IDs, `instanceId` values, webhook URLs of the live instance.

Commit messages and PR descriptions are part of the public history too: do not
name the hosting provider, domains, people or IDs there either ("fix path issue
of the deployment" instead of naming the provider).

## 2. Where such values live instead

| Value | Location (never the repo) |
|---|---|
| API keys, shop/database IDs, seller data, mail sender/recipient, Etsy invoice recipient | `app_config` table (scopes `etsy`, `notion`, `seller`, `mail`, `etsy_rc`) |
| OAuth / Notion / SMTP / Postgres logins | n8n credential store |
| DB passwords | `secrets_data` Docker volume (written by `bootstrap/`) |
| Optional bootstrap overrides | `.env` (gitignored) |

When adding a feature that needs a new instance-specific value, read it from
`app_config` and fail with a clear error if it is missing. Do not hard-code it
in a workflow, template or script, not even "temporarily".

## 3. Placeholders in code and docs

- E-mail: `…@example.org`; people: `Max Mustermann` / `Vorname Nachname`;
  business: `Mein Shop`; tax data: `123/456/78901`, `DE123456789`.
- Domains: `<deine-n8n-domain>`; IDs: `NOTION_DATABASE_ID`, `xxxxxxxx…`.
- n8n credential references in workflow JSON: `POSTGRES_CREDENTIAL_ID`,
  `ETSY_OAUTH2_CREDENTIAL_ID`, `NOTION_CREDENTIAL_ID`, `SMTP_CREDENTIAL_ID`.
- Public data of third parties is fine (Etsy/Notion API URLs, Etsy Ireland's
  company address and VAT ID).

## 4. Input from the user

Users share screenshots, exported workflows and config dumps to explain their
setup. Use them to learn **which settings** work, then write those settings
down generically: copy field names and generic values (grant type, scopes,
URLs of public APIs); replace domains, client IDs and anything account-specific
with placeholders.

Exported n8n workflows need cleaning before they are committed: replace real
credential IDs with the placeholders above, drop `pinData`, check `meta`,
`instanceId`, webhook URLs, node parameters and Code nodes for hard-coded
addresses or IDs.

## 5. Check before every commit and push

Run in the repository root. Every e-mail address, URL host and IP that shows up
must be a placeholder from section 3, a public third-party host, or internal
(`typst-api`, `localhost`, `127.0.0.1`, `0.0.0.0`):

```bash
git grep -h -o -I -E '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' | sort -u   # e-mails
git grep -h -o -I -E 'https?://[^/"'"'"' )`<>]+' | sort -u                     # URL hosts
git grep -n -I -E '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b'                             # IPs
git grep -n -I -E '\b[0-9a-f]{32}\b'                                            # Notion/n8n IDs
gitleaks dir . && gitleaks git --log-opts=--all .                               # secrets
```

Also read your own diff and commit message once with section 1 in mind; the
patterns above do not catch names or provider mentions.

## 6. If something sensitive was committed

1. Stop and tell the user what was committed and in which commits. Deleting it
   in a new commit is not enough: it stays in the history.
2. If it is a credential, it must be **rotated** (new key/password), regardless
   of any cleanup. GitHub can keep serving old commits by hash after a rewrite.
3. A history rewrite (`git filter-repo --replace-text …`) and the force-push it
   needs happen only after the user explicitly agrees. Afterwards every clone,
   including the server checkout, must be re-cloned or reset.

## 7. Git identity

Commits use the GitHub no-reply address of the account
(`<username>@users.noreply.github.com`), never a private address. That address
does not receive mail; it only links commits to the GitHub profile.

## 8. Security rules for the code itself

- **SQL in n8n Postgres nodes:** always query parameters (`$1, $2, …` with
  `options.queryReplacement` as an array expression), never `'{{ … }}'` inside
  the SQL text. Webhook input and Etsy data (titles with apostrophes) are
  untrusted.
- **Webhooks** (`generate-docs`, `etsy-rc-invoice`) have no authentication by
  default; recommend Header Auth when the n8n instance is reachable from the
  internet. Never document a live webhook URL.
- **Network:** Postgres and `typst-api` stay inside the Docker network
  `n8n-backend`; do not publish their ports in `docker-compose.yml`. The only
  published port is the optional Adminer UI (profile `tools`) on
  `127.0.0.1:8081`, reached via SSH tunnel. Never bind it to `0.0.0.0`, drop
  the IP, or route it through a public reverse proxy.
- **typst-api** rejects unknown request fields (`extra="forbid"`); keep that,
  so an outdated image fails loudly instead of rendering incomplete invoices.
