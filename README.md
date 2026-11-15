# 🤖 Open WebUI on Kubernetes

**Your local AI, ready for the whole family or team — not just you.** One
deployment turns your OpenAI-compatible model endpoint into a ChatGPT-style
workspace where every person signs in under their own account, with their
own private chat history, uploads, and settings — and gets their own `sk-`
API key, so personal scripts, IDE plugins, and apps use the shared model
under each user's own identity and permissions. The first account you create
is the admin; every new signup waits in a pending queue until you approve
them.

This repository is the deployment layer: a ready-to-run
[Open WebUI](https://openwebui.com) stack — a PostgreSQL database, a private
SearXNG web search, Redis for streaming, and nightly backups that check
themselves — on a single-node Kubernetes (K3s) cluster. Secured by default:
no container runs as root, every credential lives in a Kubernetes Secret that
K3s encrypts at rest, and Helm charts deploy the whole thing with one command.

> **🧭 New here?** Start with [What you need](#-what-you-need), then follow
> [Quick start](#-quick-start). You need a model endpoint; the Brave Search
> API key is optional (Bing answers without one). Prefer to have an AI coding
> agent drive the deployment? See
> [AI prompt for deploying with an AI agent](#-ai-prompt-for-deploying-with-an-ai-agent).

---

## 📋 Table of contents

- [✨ What you get](#-what-you-get)
- [🚫 What this repo is not](#-what-this-repo-is-not)
- [📦 What you need](#-what-you-need)
- [⚖️ Sizing by message volume](#-sizing-by-message-volume)
- [🚀 Quick start](#-quick-start)
- [🤖 AI prompt for deploying with an AI agent](#-ai-prompt-for-deploying-with-an-ai-agent)
- [❓ What the wizard asks](#-what-the-wizard-asks)
- [🔑 Where the credentials live](#-where-the-credentials-live)
- [✅ Check that it works](#-check-that-it-works)
- [⚙️ How it works](#-how-it-works)
- [🛠️ Everyday commands](#-everyday-commands)
- [🔐 Login options](#-login-options)
- [⬆️ Upgrades](#-upgrades)
- [💾 Backups and restore](#-backups-and-restore)
- [🩺 Troubleshooting](#-troubleshooting)
- [📖 Words you will see](#-words-you-will-see)
- [🔗 References](#-references)
- [📄 Licensing notes (this repository)](#-licensing-notes-this-repository)
- [🗺️ Documentation map](#-documentation-map)

---

## ✨ What you get

**👥 Built for more than one person.** This is the whole point: a local model
endpoint becomes a shared service with private per-user boundaries. Everyone
signs in with their own account (built-in form or Google sign-in), sees only
their own conversations and files, and mints their own `sk-` API keys for
programmatic access — authenticated as that user, with their role and model
access. Admins approve new signups and manage users from the web UI. See
[Login options](#-login-options).

**🪶 Lightweight.** One small Kubernetes cluster (K3s) on a single machine
runs the whole stack — app, database, search engine, cache, and the backup
jobs. No GPU, no external services beyond your model endpoint; the `small`
sizing profile starts at 4 CPU cores and 8 GB of RAM.

**🔒 Secure by default.**

- **Credentials never touch a file.** They are typed once into
  `deploy/secret-init.sh` and stored in Kubernetes Secrets that K3s encrypts
  at rest — not in `.env`, not in `values.yaml`, not in git. Helm does not own
  them, so no upgrade can rewrite or delete one.
- **Nothing critical runs as root.** The app, the database, and the search
  engine start as dedicated unprivileged users, each with `runAsNonRoot` set
  so a regression to root fails the rollout loudly instead of passing
  silently. The app and search containers additionally drop every Linux
  capability and disable privilege escalation; the search engine — the one pod
  that parses untrusted HTML from the internet — also runs under a seccomp
  profile.
- **Locked-down browser surface.** CORS is pinned to your own origin, session
  cookies are `Secure` whenever `WEBUI_URL` is `https://`, and Google sign-in
  disables the built-in login form.

**📦 The stack, wired together:**

| Piece | What it does here |
|---|---|
| **Open WebUI** | The multi-user workspace: ChatGPT-style chat with any OpenAI-compatible model, per-user history, uploads, and `sk-` API keys. Ask questions of PDFs, Word files, or text — embeddings run in-process, so there is no extra embedding service to pay for |
| **PostgreSQL** | The app's database. The nightly dump is restored into a scratch database and compared against the live one before the archive counts as a backup |
| **SearXNG** | Private web search inside the cluster — active with a Brave Search API key, with Bing as the no-key fallback. Your searches are not tied to your account |
| **Redis** | The app's WebSocket/streaming cache |

- **🔑 Login your way** — the built-in form works with no domain or TLS;
  Google sign-in needs a public `https://` URL. See
  [Login options](#-login-options).
- **💾 Backups you can trust** — verified database dumps and volume archives
  go to a **second path**, not the same disk as the live data, and
  `./deploy/backup.sh` produces a fully encrypted, round-trip-verified portable
  bundle that can rebuild a new server.
- **🚦 One command to deploy** — `./deploy/deploy.sh` reads site values from a
  private `.env` file, verifies the credential Secrets, deploys both charts in
  the right order, waits for the pods, and checks the running app. No secret is
  written to a tracked file or to `.env` at all.

## 🚫 What this repo is not

- **Not Open WebUI itself.** Open WebUI, SearXNG, PostgreSQL, and Redis are
  upstream projects. This repo is the deployment layer: charts, settings, and
  scripts.
- **Not a model server.** You bring an existing OpenAI-compatible endpoint. This
  repo only points the app at it.

## 📦 What you need

| Item | What to have |
|---|---|
| **Operating system** | Ubuntu 24.04 LTS x86_64 is the tested platform. Any systemd system with a recent kernel should work. |
| **CPU and RAM** | 4 cores and 8 GiB minimum (the `small` profile, the default). See [Sizing by message volume](#-sizing-by-message-volume) for the other profiles. Document ingestion uses about 500 MB RAM per worker. |
| **Disk** | 40 GB for the system, plus at least 50 GB for the data volume (the `small` profile). A fast SSD is better for PostgreSQL. |
| **A second path for backups** | A different directory, a second disk, or a remote mount. It **must not** be the same path as the live data. |
| **A model server** | Any OpenAI-compatible API reachable from the cluster, including the `/v1` path. Example: `http://inference.example.net:8080/v1`. Without it the app starts, but chat will not work. |
| **A Brave Search API key** | Free plan gives 2,000 searches/month: <https://brave.com/search/api/>. The scripts require a non-empty key. |
| **Network** | Open port **30000** for the app. Keep port **30432** (the database) closed to the public internet. |
| **Optional: Google sign-in** | Needs a public hostname, a TLS reverse proxy, and a Google OAuth client. |

## ⚖️ Sizing by message volume

The stack is sized by how many chat messages it will store in total, not by how
many users it serves. `MESSAGE_SCALE` in `.env` picks one of three profiles,
and each profile sets a coherent resource envelope: the CPU and memory limits
for every workload, the number of uvicorn workers, and the PostgreSQL tuning.
One knob moves the whole stack together, so the numbers can never disagree
with each other.

| Profile | Messages stored | Database | CPU | RAM | Disk |
|---|---|---|---|---|---|
| `small` (default) | 100,000 | ~2 GB | 4 cores | 8 GB | 50 GB |
| `medium` | 1,000,000 | ~20 GB | 8 cores | 16 GB | 250 GB |
| `large` | 10,000,000 | ~200 GB | 12 cores | 24 GB | 1500 GB |

These are the **minimums the deploy checks against**, not what the machine
will use. `DEPLOY_CPU_CORES`, `DEPLOY_MEMORY_GB`, and `DEPLOY_STORAGE_GB`
declare what this host can actually spare; lower them if the node also runs
other workloads. Choosing a profile the declared capacity cannot carry fails
the deploy with the exact shortfall, instead of installing something that
dies later.

**How the numbers were reached.** One stored message costs about 20 kB once
the chat JSON copy, the message row, and their indexes are counted, so the
database estimates are measured, not guessed. Documents do not go into
PostgreSQL — they go to the open-webui volume — so chat text is what drives
growth. Disk is the constraint that bites first at the high end: the Postgres
backup job keeps seven daily dumps and a compressed dump runs about a third
of the database, so `large` needs ~200 GB of database plus ~20 GB of WAL plus
~450 GB of dumps before the uploads volume is even counted.

**Changing the size.** Edit `MESSAGE_SCALE` in `.env`, raise the three
`DEPLOY_*` values if the host can spare them, and run `./deploy/deploy.sh`.
The profile raises uvicorn workers, the database pool, `shared_buffers`,
`effective_cache_size`, and `max_connections` together, which is what keeps
response time flat as the database grows. Do not hand-edit those in
`values.yaml`: they are rendered from the profile, and the next deploy
overwrites any change. A bigger profile does not need a data migration — it
gives the database more memory and connection headroom.

## 🚀 Quick start

### Step 1 — Clone the repo

```bash
git clone <this repository> && cd OpenWebUI-Kubernetes
```

### Step 2 — Prepare the server (needs `sudo`)

This installs packages, kernel settings, swap-off, K3s, and Helm. Run the
preview first; it changes nothing.

```bash
sudo ./deploy/bootstrap-root.sh --node-name open-webui --check
sudo ./deploy/bootstrap-root.sh --node-name open-webui
```

`open-webui` is the name K3s registers this machine under. Every persistent volume is
tied to that name, so **pick it once and never change it**. Changing it later
means deleting and recreating the volumes with the data moved aside.

In the `--check` output, `OK` means already done and `TODO` means the real run
would do it. Neither is an error — the verdict is the closing line,
`--check found no blocking problems`.

### Step 3 — Configure and deploy (normal user, no `sudo`)

```bash
./deploy/bootstrap-host.sh --node-name open-webui
```

This checks the server and asks you for each site setting, saving the answers
in `.env`. The wizard is the only place that asks you for a **site value** — it
never asks for a password. On a fresh machine it stops with one command left:

```bash
./deploy/secret-init.sh
```

This prompts once for every credential — database password (**Enter**
generates a strong one), session signing key (**Enter** generates), and the
optional Google SSO and Brave Search keys — and stores them **encrypted in the
K3s datastore** (K3s is installed with `--secrets-encryption`), never in `.env`
or any file. Re-run `./deploy/bootstrap-host.sh --node-name open-webui` afterwards;
the questions you answered are kept and the deploy runs through.

When it finishes, open `http://<node-ip>:30000`. **⚠️ The first account you
create becomes the admin.** Then start chatting.

> Already have K3s and Helm? Skip Step 2 and run Step 3 only. The host check
> passes quietly on an already-prepared machine, and the wizard still runs.

## 🤖 AI prompt for deploying with an AI agent

Any coding agent that reads `AGENTS.md` — Claude Code, Codex, Grok, opencode,
and most others — can drive this deployment for you. The `AGENTS.md` at the repo
root is what the agent reads on its own; the prompt below just points it at the
right scripts and keeps it out of the secrets.

Open the agent in the repo folder and copy this prompt in:

```text
Help me deploy this Open WebUI stack on this server, working from this repository.

1. Read AGENTS.md and README.md completely before running anything.
2. Run ./deploy/selftest.sh and ./deploy/deploy.sh --dry-run before changing or
   deploying anything; both must pass.
3. If the server is not prepared yet, run ./deploy/bootstrap-host.sh --node-name
   <name>. It prints any command that needs sudo — show me those and I will run them
   myself. Then answer the .env wizard question by question. Never guess a value: if
   a question needs a real key, URL, or host name, ask me first. When it stops and
   asks for ./deploy/secret-init.sh, tell me — I will type the credentials myself.
4. Never write a credential, host name, IP address, or node name into any tracked
   file. Credentials are not in .env at all: they live in Kubernetes Secrets and
   are entered only through ./deploy/secret-init.sh.
5. Deploy with ./deploy/deploy.sh only — never a bare helm command. When it finishes,
   run the checks from the "Check that it works" section and show me the output.
6. Do not commit or push anything unless I ask.
```

The agent can do the day-2 work too: ask it to "check for updates" and it runs
the bundled `check-updates` version audit (stable releases only), and the
[Troubleshooting](#-troubleshooting) section below is written so the agent can
work through it.

Two things to watch yourself, agent or no agent:

- **🔒 Pick the node name once.** It is pinned into the persistent volumes and
  cannot be changed later without moving the data.
- **👤 Sign in first.** On a fresh install the first account that signs in
  becomes the admin.

## ❓ What the wizard asks

The wizard asks one question at a time and checks each answer before saving it.
A bad URL or node name is rejected and the same question is asked again.

| Setting | What to enter |
|---|---|
| `K3S_NODE_NAME` | The name from `--node-name`. If K3s is already installed, the cluster's current node name. |
| `MESSAGE_SCALE` | `small` (100K messages), `medium` (1M), or `large` (10M). **Enter** accepts `small`. See [Sizing by message volume](#-sizing-by-message-volume). |
| `WEBUI_URL` | Without Google: `http://<node-ip>:30000`. With Google: your public `https://` URL. |
| `OPENAI_API_BASE_URL` | Your model server URL. The wizard warns if it does not end in `/v1`. |
| `LIVE_DATA_PATH` | Where live data lives. **Enter** accepts `~/.open-webui/live-data`. |
| `BACKUP_DATA_PATH` | Where backups live. **Enter** accepts `~/.open-webui/backup-data`. Must be a different path. |
| `DEPLOY_CPU_CORES`, `DEPLOY_MEMORY_GB`, `DEPLOY_STORAGE_GB` | What this host can spare for the stack. **Enter** accepts the values detected on this machine. |
| `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DB`, `POSTGRES_USER` | Standard in-cluster values. **Enter** accepts each. |

The two data paths may contain letters, digits, `.`, `_`, `-`, and `/`, plus a
leading `~`. They cannot contain spaces or shell characters such as `$()`,
quotes, or semicolons.

If you re-run the wizard, already-valid values are kept. `--configure` re-asks
every question; pressing Enter keeps the current value.

## 🔑 Where the credentials live

Not in `.env`. The wizard asks only site values; every credential is entered
once through `./deploy/secret-init.sh` and stored in three Kubernetes Secrets
that K3s encrypts at rest (it is installed with `--secrets-encryption`):

| Credential | Secret | Key |
|---|---|---|
| Database password | `postgres` | `password` |
| Session signing key + database URL | `ai-open-webui-secrets` | `WEBUI_SECRET_KEY`, `DATABASE_URL` |
| Google SSO (optional) | `ai-open-webui-secrets` | `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` |
| Brave Search key (optional) | `ai-open-webui-searxng` | `brave-api-key` |

`DATABASE_URL` is assembled by `secret-init.sh` from the `POSTGRES_*` values in
`.env` plus the password you type, so the URL and the password can never drift
apart. Values are typed at hidden prompts and reach `kubectl` through `0600`
temp files that are deleted when the script exits — never a command line (`ps`),
and never `.env`, `values.yaml`, or any tracked file. Helm does not own these
Secrets, so an upgrade can never rewrite or delete a credential.

A fingerprint manifest, `secrets.manifest` at the repo root (gitignored), records
an HMAC of each value under a random salt — enough to detect a rotated or drifted
Secret, never enough to recover one. Verify any time:

```bash
./deploy/secret-init.sh --check
```

**Rotation (database password).** The database honours its password from
initialisation only, so the order matters: change it in Postgres first, then
tell the Secret, then restart the app. Open an interactive `psql` so the new
password never lands on a command line or in the process list:

```bash
kubectl exec -it deploy/postgres -n default -- psql -U openwebui -d postgres
# at the psql prompt:  ALTER USER openwebui WITH PASSWORD '<new>';

./deploy/secret-init.sh        # re-enter every credential: the same values as
                               # before, except the rotated password. Enter on a
                               # required prompt GENERATES a new random value and
                               # Enter on an optional one SKIPS it, so press
                               # Enter only where that is what you want.
kubectl rollout restart statefulset/ai-open-webui -n default
```

`secrets.manifest` records the new fingerprints; until you re-run
`secret-init.sh`, every `--check` reports drift for the rotated value — that is
the point.

The durable copy of every credential is the encrypted backup bundle (see
[Backups](#-backups-and-restore)) — lose the host and the bundle and the
credentials are gone by design.

## ✅ Check that it works

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:30000/health   # expect 200
kubectl get pods -n default                                             # expect 1/1 Running
```

Then do a three-minute smoke test in the app:

1. **💬 Send a chat message** — proves the model endpoint works.
2. **📄 Upload a PDF and ask about it** — proves document chat and embeddings
   work.
3. **🔍 Turn on web search for the next message** — proves SearXNG works.

`kubectl get pods` alone is not proof the app is serving. Check `/health` as
well.

### If the app sits behind a reverse proxy

Check the public address, not just `localhost`. These four commands catch the
failures a proxy introduces:

```bash
# 1. The public URL serves THIS deployment, not an older one
curl -s https://ai.example.com/api/config \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['version'])"

# 2. WebSocket upgrade. Use --http1.1: browsers open WebSockets over HTTP/1.1, and an
#    Upgrade header sent over HTTP/2 makes the app answer 400 "Invalid WebSocket upgrade
#    request" — a false alarm, not a proxy fault.
curl -s -o /dev/null -w "%{http_code}\n" --http1.1 \
  -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  "https://ai.example.com/ws/socket.io/?EIO=4&transport=websocket"     # expect 101

# 3. The OAuth callback route survives the proxy. 307 or 400 means the route was reached;
#    404 means the proxy rewrote the path.
curl -s -o /dev/null -w "%{http_code}\n" https://ai.example.com/oauth/google/callback

# 4. Redirects stay on https. A location: starting with http:// breaks Secure cookies.
curl -s -o /dev/null -D - https://ai.example.com/oauth/google/callback | grep -i '^location:'
```

If (1) prints an older version, the proxy still points at the previous backend —
no amount of redeploying here will change that.

## ⚙️ How it works

```
deploy/
├── bootstrap-root.sh   ← run with sudo: packages, kernel settings, K3s, Helm
├── bootstrap-host.sh   ← run as your user: host checks, .env wizard, then setup.sh
├── secret-init.sh      ← one-time credential entry: prompts → Kubernetes Secrets
├── setup.sh            ← first deploy: checks, host folders, Secret checks, then deploy.sh
├── deploy.sh           ← everyday deploy: PostgreSQL first, then Open WebUI
├── cluster/manifests/  ← the StorageClass and the open-webui volume no chart owns
├── postgresql/         ← PostgreSQL chart and its backup CronJob
└── open-webui/         ← Open WebUI chart, SearXNG, Redis, uploads backup CronJob
```

Each component folder is self-contained: its own chart, `values.yaml`, and
`deploy.sh`. `deploy/deploy.sh` is the only script you normally run.

Four rules matter before you change anything:

1. **🔐 Site values live in one private `.env` file** at the repo root; every
   **credential lives in a Kubernetes Secret**, entered once through
   `deploy/secret-init.sh` and encrypted at rest by K3s. No tracked file and no
   `.env` line ever holds a password. The scripts refuse to run if `.env` is
   missing, visible to git, or incomplete — and refuse to deploy without the
   Secrets. See [.env.example](./.env.example).
2. **📍 Everything is tied to one node.** The local volumes name the K3s node in
   `K3S_NODE_NAME`. This is the `kubernetes.io/hostname` label, which is not
   always what `hostname` prints. A mismatch is the most common fresh-install
   failure: volumes stay `Pending` with no useful error.
3. **💾 Backups go to a second path.** The live root (`LIVE_DATA_PATH`) holds the
   database, uploads, and vector store. The backup root (`BACKUP_DATA_PATH`)
   holds the nightly archives. Put them on different physical devices, or make
   the backup root a remote mount. One disk holding both the data and its only
   backup dies together.
4. **👤 The data tree belongs to you, not root.** Run `./deploy/setup.sh` as your
   normal user: it creates the tree owned by you, and the app and backup pods
   run as you, so every file they write stays yours. Never run it with sudo —
   that is how a tree ends up root-owned, and digging it back out needs
   `sudo chown` afterwards.

## 🛠️ Everyday commands

```bash
./deploy/deploy.sh                # deploy any chart or .env change
./deploy/deploy.sh --dry-run      # lint and render both charts; changes nothing
./deploy/deploy.sh --check        # compare .env with both live releases
./deploy/deploy.sh open-webui     # deploy only one component
./deploy/deploy.sh --pinned       # use values.yaml pins even on a fresh install
./deploy/selftest.sh              # test the scripts themselves; no cluster needed

kubectl get pods -n default
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:30000/health   # 200
kubectl logs -n default -l app.kubernetes.io/component=open-webui
helm history ai-open-webui -n default
```

`deploy.sh` deploys PostgreSQL first because Open WebUI connects to it during
startup. It stops at the first component that fails, so a broken database does
not produce confusing app errors later.

On a brand-new machine, the first deploy may choose the newest stable image tags
from the registries. After that, deploys follow the pins in `values.yaml`
exactly, so upgrades stay deliberate and reviewable. `--pinned` skips the
first-install choice and uses the pins from the start.

> **⚠️ Prefer `./deploy/deploy.sh` over a bare `helm upgrade`.** Helm merges
> values per key, so a partial command silently resets anything left out. The
> credentials are safe from this now — they live in pre-created Secrets that
> Helm neither renders nor rewrites — but the site values (node name, data
> paths, profile sizing) still come from `.env` through the deploy scripts, and
> the scripts also verify the Secrets exist *before* Helm runs, failing with the
> exact fix instead of `CreateContainerConfigError` after a rollout.

One app behavior to know: `ENABLE_PERSISTENT_CONFIG: "true"` means the app's own
`config` table can override `values.yaml`. If a setting looks ignored, check the
database. A hand-run `update config ...` in psql changes nothing until the pod
restarts:

```bash
kubectl exec deploy/postgres -n default -- psql -U openwebui -d openwebui -tAc \
  "select value from config where key='openai.api_base_urls'"
```

## 🔐 Login options

### Built-in login form (simplest)

Skip both Google prompts in `./deploy/secret-init.sh` (**Enter** on the first).
The app uses its built-in login form. The first account to sign up becomes the
admin. You reach the app at `http://<node-ip>:30000` with no reverse proxy, no
TLS certificate, and no Google project.

`deploy.sh` sees the absent pair in the Secret and sets `ENABLE_LOGIN_FORM=true`
and non-`Secure` cookies for you.

### Google sign-in

Enter both the client ID and the client secret at the Google prompts in
`./deploy/secret-init.sh` (typing one without the other is rejected). The deploy
turns off the login form and enables Google sign-in. You also need:

1. **A public hostname** with DNS pointing at a reverse proxy, and a TLS
   certificate on that proxy. TLS is required: session cookies are marked
   `Secure`, so Google login over plain HTTP will not work.
2. **A reverse proxy** forwarding `443` to `node:30000`, with WebSocket upgrade
   enabled. Chat streaming uses WebSockets. A proxy that buffers silently makes
   the UI look stuck instead of showing an error.
3. **A Google OAuth client** (about 10 minutes in
   [Google Cloud Console](https://console.cloud.google.com)):
   1. Create or select a project.
   2. **APIs & Services → OAuth consent screen → External.** Set the app name
      and emails. The default scopes (`openid`, `email`, `profile`) are what
      Open WebUI asks for. Add your address under **Test users** while in
      Testing mode, or publish the app.
   3. **APIs & Services → Credentials → Create credentials → OAuth client ID →
      Web application.**
   4. **Authorised JavaScript origins:** your `WEBUI_URL`, for example
      `https://ai.example.com`.
   5. **Authorised redirect URIs:** `WEBUI_URL` plus `/oauth/google/callback`:
      `https://ai.example.com/oauth/google/callback`. Google rejects anything
      else with `redirect_uri_mismatch`.
   6. Copy the client ID and secret into `./deploy/secret-init.sh` at its
      Google prompts.

**👤 The first account to sign in becomes the admin automatically.** This is true
even though `DEFAULT_USER_ROLE` is `pending`: the app's first-user bootstrap
promotes the only account on its first login, overriding that default. You do
not need to run any SQL to get started.

That also means **the first person to reach the URL becomes admin**. Sign in
yourself immediately after the first deploy, before you share the address with
anyone.

Everyone after the first starts as `pending`. Approve them in **Admin Settings →
Users**.

To promote or repair a different account later:

```bash
kubectl exec -it deploy/postgres -n default -- \
  psql -U openwebui -d openwebui -c "update \"user\" set role='admin' where email='you@example.com';"
```

## ⬆️ Upgrades

**Check what is outdated.** Ask an agent to "check for updates". The bundled
`check-updates` skill (`.agents/skills/check-updates/`) queries Docker Hub,
GitHub releases, and the Helm repo live, then reports Current / Latest-GA /
Status. Its policy is **GA only**: no `-dev`, `-rc`, or `-alpha` tags. A newer
major version of PostgreSQL is not a routine bump; it is a dump-and-restore
project.

**Routine upgrade (patch or minor):**

1. Edit the image tag in the right `values.yaml`. To upgrade the Open WebUI
   chart itself, edit the dependency `version` in
   `deploy/open-webui/Chart.yaml`. There is no `Chart.lock`; the next deploy
   pulls the pinned version.
2. Update `appVersion` in the matching `Chart.yaml` so it matches the new pin.
3. **💾 Take a database dump first** — see
   [Backups and restore](#-backups-and-restore).
4. Run `./deploy/deploy.sh`.
5. Confirm the pod really runs the new image. K3s reuses its local image cache,
   so "deployed" does not always mean "upgraded":

   ```bash
   kubectl get pod -n default ai-open-webui-0 \
     -o jsonpath='{.spec.containers[0].image}'
   ```

**Rollback:** run `helm history ai-open-webui -n default`, then
`helm rollback ai-open-webui <revision> -n default`. Or re-pin the old tag and
deploy again. If a database migration already ran, restore the pre-upgrade dump
first.

**PostgreSQL major versions:** the image will not open a data directory from
another major version. Move the old data aside, let the new pod initialize an
empty database, restore the dump, and re-apply ownership (a `--no-owner` dump
drops it).

**Rotating the PostgreSQL password:** the password lives in the `postgres` Secret
(`./deploy/secret-init.sh`), and the database honours it only when the data
directory is first initialized. Changing it means both places, in this order:

1. `ALTER USER` in psql — the database accepts the new password.
2. `./deploy/secret-init.sh` — update the Secret (and the `DATABASE_URL` built
   from it); `secrets.manifest` records the new fingerprint.
3. Run `kubectl rollout restart statefulset/ai-open-webui -n default`. Editing a
   Secret does not change the pod template, so no rollout happens without this.
4. Run `./deploy/secret-init.sh --check` and `./deploy/deploy.sh --check`.

## 💾 Backups and restore

There are two layers of backup. The **nightly archives** (below) are local and
unencrypted and keep a short window — they are for recovering from a bad deploy
or a single clobbered file. The **portable encrypted bundle**
(`./deploy/backup.sh`) is the full, complete restore — every setting, every
credential, every byte of data — in one GPG-encrypted file you can carry to a
new server.

`<LIVE>` and `<BACKUP>` below mean the values of `LIVE_DATA_PATH` and
`BACKUP_DATA_PATH` in `.env`. Load them into your shell once per session:

```bash
set -a; . ./.env; set +a
```

### Nightly archives (CronJobs)

| Data | Where it goes | When | Kept |
|---|---|---|---|
| `openwebui` database | `<LIVE>/postgresql-backups`, plus a verified copy on `<BACKUP>/postgresql` | daily at 02:00 UTC | 7 days |
| Open WebUI volume: `uploads/`, `vector_db/`, `cache/` | `<BACKUP>/open-webui` | daily at 02:30 UTC | 4 days |

`backup.databases` lists only the `openwebui` database, because that is the only
one this deployment creates. A database listed there that does not exist makes
the whole backup run fail — add an entry only after the database exists.

What makes these backups trustworthy:

- **✅ The PostgreSQL job checks four things.** `gzip -t` passes, the dump ends
  with the `PostgreSQL database dump complete` line, a restore into the
  `restore_verify` scratch database matches the live table list, and the
  second-disk copy also passes. Anything that fails is deleted, so a broken file
  never looks like a restore point.
- **✅ The uploads job checks three things.** `gzip -t`, `tar -t`, and the member
  count. It proves the archive is readable, not that extraction works.
- **⏰ Both jobs have a one-hour start deadline.** Without it, a job missed while
  the node was down is skipped silently, and the newest archive quietly ages out
  of the retention window.

```bash
kubectl get jobs -n default -o wide
kubectl logs -n default -l app.kubernetes.io/component=backup --tail=15 --prefix
kubectl logs -n default -l app.kubernetes.io/component=uploads-backup --tail=5 --prefix
ls -lh "$BACKUP_DATA_PATH"/postgresql "$BACKUP_DATA_PATH"/open-webui
```

Run a backup now:

```bash
JOB=pg-backup-$(date +%s)
kubectl create job "$JOB" -n default --from=cronjob/postgres-backup
kubectl wait --for=condition=complete job/"$JOB" -n default --timeout=300s
kubectl logs -n default job/"$JOB"
```

**Restore the database.** This overwrites current data and returns it to the
moment of the dump. The PostgreSQL pod does not mount the backup folder, so
stream the file from the node. Use `exec -i`, not `-it`:

```bash
gzip -dc "$LIVE_DATA_PATH"/postgresql-backups/openwebui_<stamp>.sql.gz | \
  kubectl exec -i deploy/postgres -n default -- psql -U openwebui -d openwebui
```

To test an archive without touching live data, restore it into a scratch
database (`CREATE DATABASE restore_check ...`), check a row count, then drop it.
To recover one uploaded file, list the volume archive with `tar -tzf` and
extract the one member with `tar -xzf`.

### Portable encrypted bundle

The nightly archives do **not** cover everything: they carry no `.env` and no
credential Secret, the volume job archives only the Open WebUI volume (not the
SearXNG state), they keep only 7/4 days, and they are unencrypted. If you want
to move this deployment to another server, or protect it against a total loss,
make a portable bundle:

```bash
./deploy/backup.sh                    # prompts for a passphrase twice
./deploy/backup.sh --dest /mnt/backup # somewhere NOT under LIVE_DATA_PATH
```

The bundle is a single GPG-symmetric (AES256) file,
`open-webui-backup_<stamp>.tar.gz.gpg`. Decrypted with the passphrase it holds
everything a new server needs to run the identical stack:

| Member | What it is |
|---|---|
| `env.env` | the `.env` — every site value (credentials are not in the file) |
| `secrets.env` | every credential Secret, base64 per key under a `#secret <name>` header |
| `secrets.manifest` | the credential fingerprints, so the restore proves the values survived bit-exact |
| `manifest.txt` | versions, node name, chat row count, restore instructions |
| `db/<name>_<stamp>.sql.gz` | one `pg_dump` per database (gated: non-empty + trailer) |
| `volumes/open-webui.tar.gz` | the whole `open-webui` volume: `uploads/`, `vector_db/`, `cache/` |
| `volumes/searxng.tar.gz` | the SearXNG config and state |

Before it is handed over the bundle is **verified by being decrypted again**
with the passphrase into a throwaway directory and every member checked (dump
trailer, gzip integrity, tar listing, manifest keys). A bundle that does not
verify is deleted.

The passphrase is the only copy of the key. The script stores no passphrase and
the bundle is useless without it — keep it where it will not die with the
server (a password manager, on paper, on another machine). It must be at least
8 characters.

For a scripted or agent run there is no second prompt: write the passphrase to a
file and pass it in. The file must be mode `0600` or the script refuses.

```bash
umask 077; printf '%s\n' "$MY_PASS" > /path/to/pp; chmod 600 /path/to/pp
./deploy/backup.sh --dest /mnt/backup --passphrase-file /path/to/pp
rm -f /path/to/pp
```

**Restore the bundle** onto the same or a different server:

```bash
./deploy/restore.sh /mnt/backup/open-webui-backup_<stamp>.tar.gz.gpg
```

Restore runs straight through — the bundle's passphrase is the only
confirmation, and the bundle is verified before anything is touched:

1. decrypt and verify the bundle,
2. install the bundle's `.env` over the current one (a copy is kept as
   `.env.pre-restore_<stamp>`; the node name is forced to this server's, because
   local PVs pin it and the field is immutable), then **rebuild the credential
   Secrets from the bundle's `secrets.env`** — the fingerprints recorded in
   `secrets.manifest` prove each value arrived bit-exact,
3. install the stack (`./deploy/setup.sh` if absent, `./deploy/deploy.sh` if
   present),
4. stop the app, recreate each database from its dump, extract the volumes,
5. start the app and verify `/health` and the chat row count against the
   manifest.

It will **not** bootstrap the host: if K3s is not running it stops and points
at `./deploy/bootstrap-root.sh` and `./deploy/bootstrap-host.sh`. Restoring onto
a running stack **replaces its data** — deliberate — but only when
the bundle's data roots match the host's: local PVs pin the paths and the field
is immutable, so a bundle from another root is refused before anything changes.
Until you are sure the new server is healthy the bundle is still the only
complete copy; keep it until then.

### Remove the stack

The stack is removed in four stages by `./deploy/uninstall.sh`, which asks one
small arithmetic question before the first stage that still has work to do
(three tries at the question; a wrong answer stops the run with nothing
changed). There is deliberately **no** `--yes` flag: a destructive run always
stops for a human. A rerun after a partial run **resumes**: stages whose work
is already done are skipped, so you can stop anywhere and pick it up later.

```bash
./deploy/uninstall.sh --check   # show exactly what every stage would touch;
                                # changes nothing, asks nothing
./deploy/uninstall.sh           # run the stages in order; one gate at the start
./deploy/uninstall.sh 3         # run ONLY stage 3 (refuses if 1-2 are undone)
```

Before stage 1, in a sequential run, the script **offers to make an encrypted
backup bundle first** (`./deploy/backup.sh`) — skipped automatically when there
is nothing left to bundle (no `.env`, or the stack is already uninstalled). Say
yes if anything in this deployment is worth keeping: after stage 3 there is no
`.env`, no database, and no volume left on the host, and the nightly archives do
not cover the settings.

| Stage | What it does | What survives |
|---|---|---|
| 1 | `helm uninstall ai-open-webui` and `postgres` | all data (PVs are `Retain`; host paths untouched) |
| 2 | delete the cluster objects the releases do not own: the `open-webui` PV and PVC, the `local-storage` StorageClass, the three credential Secrets (`postgres`, `ai-open-webui-secrets`, `ai-open-webui-searxng` — Helm never owned them, so it never deletes them), and any leftover release-owned PV/PVC | the host directories |
| 3 | delete the host data: the `LIVE_DATA_PATH` and `BACKUP_DATA_PATH` trees (escalated with sudo — parts of the tree belong to the container users, uid 70 and 977), the `.env` file and the `secrets.manifest`; refuses to continue if anything survives | nothing under those roots |
| 4 | return the host: uninstall K3s, remove `/usr/local/bin/helm`, remove the apt packages the bootstrap installed **only if nothing else uses them** (the rest are listed with their dependents), remove `/etc/modules-load.d/k3s.conf` and `/etc/sysctl.d/99-k3s.conf`, and re-enable swap from the fstab backup | a clean host |

Stage 3 names **every** previous backup it is about to delete — a count and a
total size — before it asks. Stage 4 never removes an apt package that an
installed package depends on: apt's own dry-run decides, and the listing shows
what keeping it would cost. It also keeps the packages the repo's own scripts
run with (`python3`), which apt's graph cannot see. A data root that is a mount
point has its contents removed, never the mount point itself.

If you only want to stop the services and keep every byte (a re-install finds it
again), stage 1 alone is enough:

```bash
./deploy/uninstall.sh 1
```

## 🩺 Troubleshooting

Work through these in order:

1. `./deploy/deploy.sh --check` — rules out `.env` drift in both components.
2. `./deploy/setup.sh --check` — re-runs every prerequisite check and changes
   nothing.
3. `kubectl get pods -n default` — `CreateContainerConfigError` means a
   credential Secret is missing or missing a key; run
   `./deploy/secret-init.sh --check`, then re-run `./deploy/secret-init.sh` if
   it names a gap.
4. `kubectl describe pod <pod>`, `kubectl logs <pod>`, and
   `helm get values <release> -n default`.

| Symptom | Likely cause | Fix |
|---|---|---|
| Volumes stuck `Pending` | `K3S_NODE_NAME` does not match the `kubernetes.io/hostname` label, or the host folder under `LIVE_DATA_PATH` does not exist | Compare `kubectl get nodes -o wide` with `.env`. `./deploy/setup.sh --check` reports both. |
| PostgreSQL in `CrashLoopBackOff` | `<LIVE>/postgresql` is missing, or a parent folder is not writable by UID 70 (the database runs non-root) | `sudo install -d -o 70 -g 70 -m 0755 "$LIVE_DATA_PATH/postgresql"` |
| Login fails with an unclear provider error | `WEBUI_URL` does not match the registered redirect URI, DNS does not resolve, or you are on plain HTTP (`Secure` cookies will not stick) | Register exactly `WEBUI_URL` + `/oauth/google/callback`; fix DNS/TLS; or clear the Google keys and use the login form. |
| Pod is `1/1 Running` but `/health` returns `000` | A database migration is hung, often because an orphaned `pg_dump` holds a lock | Find the `ClientWrite` session and run `select pg_terminate_backend(<pid>);` |
| Web search stopped working | No Brave key was entered in `secret-init.sh` (no `ai-open-webui-searxng` Secret exists), or the SearXNG pod predates the key | `./deploy/secret-init.sh --check` reports the gap; enter the key and restart the SearXNG pod. |
| `conflict with "kubectl-..." ... ENABLE_LOGIN_FORM` | A previous `kubectl patch` claimed ownership of the field | Re-run with `--force-conflicts`. |
| SearXNG settings look wrong | UI edits are lost on restart; the init container rewrites `settings.yml` from the chart on every pod start | Edit `deploy/open-webui/charts/searxng/templates/deployment.yaml`, then restart the pod. |
| Backup job fails with `Permission denied` writing `/backups/...`, or `install: can't change permissions` on the off-disk path | The Postgres job runs as UID 70; `postgresql-backups` under `<LIVE>` and `postgresql` under `<BACKUP>` are still owned by your user from a no-sudo `setup.sh` run | `sudo chown 70:70 "$LIVE_DATA_PATH/postgresql-backups" "$BACKUP_DATA_PATH/postgresql"` — or, with no sudo, `chmod o+w` on just those two directories |
| Backup job fails with `database "x" does not exist` | `backup.databases` names a database that was never created. A missing entry fails the whole run even though every other dump verified | Remove it from `deploy/postgresql/values.yaml` and re-run `./deploy/deploy.sh postgresql`. Add a database only after it exists. |
| Public URL shows an older version than `localhost:30000` | The reverse proxy still points at the previous backend | Repoint its backend at `<node-ip>:30000`. Confirm with the four commands under [Check that it works](#-check-that-it-works). |
| WebSocket test returns 400 `Invalid WebSocket upgrade request` | The test sent an `Upgrade` header over HTTP/2, which is invalid. Browsers use HTTP/1.1 for WebSockets | Re-run the test with `--http1.1`. If it then returns 101, nothing is broken. |
| `bootstrap-host.sh` says a kernel module is not loaded, but `modprobe` succeeds | The module is compiled into the kernel (`CONFIG_...=y`), so `lsmod` never lists it | Check `ls -d /sys/module/overlay /sys/module/br_netfilter`. If both exist, the feature is present. |
| `./deploy/selftest.sh` fails with `Chart.lock exists` | `helm dependency build` wrote a lock file. This repo pins exact versions in `Chart.yaml` and carries no lock | `rm deploy/open-webui/Chart.lock`. `./deploy.sh` now deletes it after every build, and `.gitignore` covers it. |
| On a fresh database the app pod restarts once during its first rollout | The app runs its workers (3 in the `small` profile); on a brand-new database they all try to write the default settings at the same time, and one fails and triggers a restart. The second start is clean | Nothing. It happens once, before the pod is ever marked Ready, and cannot repeat once the settings are written. Repeated restarts are a different problem — check `kubectl logs <pod>`. |
| The deploy stops with `MESSAGE_SCALE=... is sized for ... and needs at least N CPU cores / GB of RAM / GB of disk` | The chosen profile needs more CPU, RAM, or disk than the `DEPLOY_*` keys declare | Raise `DEPLOY_CPU_CORES`, `DEPLOY_MEMORY_GB`, or `DEPLOY_STORAGE_GB` in `.env` to what the host can spare, or choose a smaller `MESSAGE_SCALE`. |

These log lines are normal and harmless:

- SearXNG: `ahmia: can't register engine` and `torch: can't register engine`
  (Tor-only engines).
- SearXNG: `missing config file: /etc/searxng/limiter.toml`.
- `/api/models` returns `401` to an unauthenticated curl.
- One connection-error line per unreachable model endpoint on each model-list
  refresh.
- `helm lint` warns `icon is recommended` and `missing required values` before
  `.env` is supplied. A value-less `helm template` failing on a required
  `nodeName`/path is by design.
- The app: repeated
  `ERROR:root ... Permission denied: '/app/backend/open_webui/static/...'` lines
  at startup. The app tries to rewrite bundled web files in a spot it does not
  own (it runs as your user, not root) and gives up; the files already exist, so
  nothing is missing.

## 📖 Words you will see

| Word | Meaning |
|---|---|
| **K3s** | A small Kubernetes distribution. It runs the containers. |
| **Helm** | A package manager for Kubernetes. A **chart** is a package. A **release** is an installed chart. |
| **Pod** | One running container (or a small group). |
| **PV / PVC** | Persistent Volume and Persistent Volume Claim: the disk and the request for it. |
| **NodePort** | A port opened on the node so you can reach a service from outside. |
| **`.env`** | The private file at the repo root that holds your site values (node name, URLs, paths). Credentials live in Secrets, not here. |
| **`secret-init.sh`** | The one-time credential entry: prompts at hidden input, stores every secret in an encrypted Kubernetes Secret. |
| **MESSAGE_SCALE** | The sizing profile — `small`, `medium`, or `large` — chosen by how many chat messages you expect to store. |
| **Inference endpoint** | The URL of the model server that answers chat requests. |
| **RAG** | Retrieval-Augmented Generation: the app looks in your uploaded documents before answering. |

## 🔗 References

- **Open WebUI:** [docs](https://docs.openwebui.com) ·
  [GitHub](https://github.com/open-webui/open-webui) ·
  [Helm chart](https://github.com/open-webui/helm-charts) — BSD-3-Clause
- **SearXNG:** [docs](https://docs.searxng.org) — AGPL-3.0
- **PostgreSQL:** [docs](https://www.postgresql.org/docs/) — PostgreSQL License
- **Redis:** [docs](https://redis.io/docs/) — RSALv2/SSPLv1/AGPLv3 (fine for
  self-hosting; the restrictions target offering Redis as a service)
- **K3s:** [docs](https://docs.k3s.io) · **Helm:** [docs](https://helm.sh/docs/)
- **Brave Search API:** [terms and pricing](https://brave.com/search/api/)
- **Google OAuth:**
  [branding guidelines](https://developers.google.com/identity/protocols/oauth2/branding)

## 📄 Licensing notes (this repository)

- **This repo is MIT** (see [LICENSE](./LICENSE)). Its own content — scripts,
  charts, values, and docs — is original and not derived from any copyleft
  component, so it is free to reuse under MIT.
- **Open WebUI** ships under its own "Open WebUI License": BSD-3 style with a
  branding condition — deployments with **more than 50 end users in a rolling
  30 days** may not alter or remove the "Open WebUI" name or logo without
  permission or an enterprise license; smaller self-hosted use is exempt, and
  earlier releases keep their prior BSD-3 terms. Leave the branding alone and
  you are compliant.
- **SearXNG** is AGPL-3.0. Copyleft bites only if you modify SearXNG's *source*
  and offer the result over a network. The local `searxng` subchart here is
  deployment configuration (it generates `settings.yml`), not a derivative
  work of SearXNG.
- **Redis** 8 and later are tri-licensed (RSALv2 / SSPLv1 / AGPLv3 — pick the
  one that fits). RSALv2's only real restriction is reselling Redis itself as
  a managed service; using it as this app's internal cache is fine under any
  of the three.
- **PostgreSQL** (PostgreSQL license), **K3s** and **Helm** (Apache-2.0), the
  upstream **open-webui Helm chart** (MIT, declared in its `Chart.yaml`), and
  the Alpine base images (permissive; busybox is GPL-2.0) are all freely
  usable for this kind of deployment.
- **Not affiliated.** This project is not affiliated with, endorsed by, or
  sponsored by Open WebUI Inc.; the name is used descriptively — this repo
  deploys Open WebUI. "Open WebUI" and related marks belong to their owners.
- **Read the service terms** before exposing the app publicly: Brave Search
  API rate limits, Google OAuth branding guidelines (do not alter the Google
  button), and your model provider's terms. This repo deploys the UI; it does
  not license the models.

## 🗺️ Documentation map

- **This file** — the guide for people: what it is, quick start, settings,
  operations, upgrades, backups, troubleshooting.
- [AGENTS.md](./AGENTS.md) — instructions for AI coding agents: conventions,
  gotchas, and per-chart detail.
- `deploy/bootstrap-root.sh`, `deploy/bootstrap-host.sh`, `deploy/secret-init.sh`,
  `deploy/setup.sh`, and `deploy/deploy.sh` — header comments document every mode
  and what each refuses to do.
- `deploy/selftest.sh` — the no-cluster test for the scripts themselves.
- `deploy/cluster/manifests/` — objects no chart owns. The PV/PVC file is a
  template with `${K3S_NODE_NAME}` and `${LIVE_DATA_PATH}`; **do not apply it
  with `kubectl -f` directly**.
- `.env.example` — the tracked template: every key, its purpose, and what an
  empty value means.
- `.agents/skills/check-updates/SKILL.md` — the live version audit and its
  GA-only policy. The single copy.
