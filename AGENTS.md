# AGENTS.md

Instructions for AI coding agents working in this repository. **This is the only
instructions file in the repo** — there are no per-directory `AGENTS.md` files and no
`CLAUDE.md` or `GEMINI.md` stubs. Keep it that way: write every instruction here, and put
nothing in a chart directory.

Agents that follow the [agents.md](https://agents.md) convention find this file by walking
up from the working directory, so one root file covers work inside `deploy/postgresql/` and
`deploy/open-webui/` too. Grok, Codex and opencode read `AGENTS.md` directly. Claude Code
auto-loads `CLAUDE.md` and the Gemini CLI defaults `context.fileName` to `["GEMINI.md"]`;
neither filename exists here, so Claude Code gets no instructions file — its skills still
load — and Gemini CLI starts with no instructions file (add a `.gemini/settings.json`
pointing `context.fileName` at `AGENTS.md` if Gemini is ever installed).

Human-facing setup, operations and troubleshooting live in [README.md](./README.md), which
is likewise a single file at the repo root.

## Skills

Reusable procedures live in `.agents/skills/`, one directory per skill holding a `SKILL.md`
with YAML front matter (`name`, `description`). That directory is the **only** copy: no
agent gets its own directory of skill content, and no skill is duplicated anywhere.

| Agent | How it reaches a skill |
|---|---|
| Codex | scans `.agents/skills/` natively |
| Claude Code, opencode | scan `.claude/skills/`, and no `.claude/` exists here — add one symlink per skill into `.agents/skills/` if these agents are installed (snippet below) |
| Grok | scans `.grok/skills/` only, and no `.grok/` exists here — add a symlink if Grok is installed |
| Gemini CLI | no `.gemini/` exists here — add a `settings.json` pointing `context.fileName` at `AGENTS.md` if Gemini is installed |

Any agent without a skills scanner reads the same file through this document. Add a skill by
creating the directory in `.agents/skills/`; only agents that scan their own directory need
the symlink:

```bash
mkdir -p .agents/skills/<name>
# only if a .claude/-scanning agent (Claude Code, opencode) is installed:
mkdir -p .claude/skills/<name>
ln -s ../../../.agents/skills/<name>/SKILL.md .claude/skills/<name>/SKILL.md
```

Never copy a `SKILL.md` into a second directory. The symlink is what keeps every agent
reading one file, so an edit in `.agents/skills/` takes effect everywhere at once.

## Repository Overview

Helm-based deployments for AI services on a **single-node Kubernetes (K3s)
cluster**. Everything that deploys lives under `deploy/`: one directory per
component and one entry-point script.
No git submodules. The former `llama.cpp-deploy/` was dropped in an earlier migration.

```
deploy/
├── bootstrap-root.sh ← RUN WITH SUDO: the only host installer (apt, modules, sysctl, swap-off, K3s, helm)
├── bootstrap-host.sh ← main entry point (normal user): validates the host, runs the .env wizard, hands off to setup.sh
├── secret-init.sh ← one-time credential entry: prompts → three Kubernetes Secrets (+ fingerprint manifest)
├── setup.sh       ← first-time setup; run this on a new machine
├── deploy.sh      ← the steady-state entry point; run this after a change
├── backup.sh      ← portable encrypted backup bundle (GPG AES256), round-trip verified
├── restore.sh     ← restore a backup bundle onto the same or a new host
├── uninstall.sh   ← staged uninstall (4 stages) with a stage-0 backup offer
├── smoke-test.sh  ← layered no-browser health check (tiers 1-6); read-only except two manual jobs
├── cluster/       ← manifests for the three objects no chart owns
├── postgresql/    ← PostgreSQL chart + its deploy.sh
└── open-webui/    ← Open WebUI chart, SearXNG subchart + its deploy.sh
```

| Directory | Deploys | Helm release | Notes |
|---|---|---|---|
| `deploy/bootstrap-root.sh` | apt packages, kernel modules, sysctl, swap-off, K3s, helm v4 | — | **sudo**; the only script that changes the host; idempotent |
| `deploy/bootstrap-host.sh` | host validation, `.env` wizard, then `setup.sh` | — | normal user; never calls sudo itself |
| `deploy/setup.sh` | prerequisite checks, host paths, cluster primitives, in-cluster credential-Secret verification, then `deploy.sh` | — | idempotent; `--check` changes nothing; never prompts for human keys (bootstrap-host.sh owns the wizard, secret-init.sh owns the credentials) |
| `deploy/backup.sh` | portable encrypted backup bundle (`.env`, credential Secrets, dumps, both volumes) | — | GPG symmetric AES256; `--dest`, `--passphrase-file` (mode 600); round-trip verified before handover |
| `deploy/restore.sh` | a backup bundle onto the same or a new host | — | decrypt+verify, `.env`, credential-Secret rebuild from the bundle, setup/deploy, DB + volume restore, verify; passphrase is the only confirmation; refuses to bootstrap the host (points at bootstrap-*) |
| `deploy/uninstall.sh` | staged uninstall, 4 stages, with a stage-0 backup offer | — | `--check` is plan mode; one arithmetic gate at the start of the run (three tries); no `--yes`; every stage prompt names what that stage will delete before the [y/N]; stage 2 deletes the credential Secrets, stage 3 deletes `.env` + `secrets.manifest` and names every previous backup; stage 4 removes apt packages only if unused and not needed by the repo's own scripts |
| `deploy/smoke-test.sh` | nothing — it verifies | — | layered no-browser health check (scripts, charts, drift, cluster shape, app serving, app function, backup gate lines); `--quick`/`--no-backup` skip the slow tiers; `SMOKE_API_KEY` unlocks the per-user chat-completion test (env only, never argv); exit 1 on any failure |
| `deploy/cluster/manifests/` | `local-storage` StorageClass, `open-webui` PV + PVC | — | applied by `setup.sh`; the PV/PVC file is a template with the node name and the live data root in it |
| `deploy/postgresql/` | PostgreSQL 18 (Alpine) + backup CronJob | `postgres` | release name is mandatory, see gotchas |
| `deploy/open-webui/` | Open WebUI + SearXNG + Redis + uploads backup CronJob | `ai-open-webui` | connects to Postgres at startup; image and chart versions live in `Chart.yaml`/`values.yaml` |

`deploy/deploy.sh` runs the component scripts in dependency order and prints one status
block for the stack; it is the only thing you should normally execute. Each component
directory stays self-contained: its own chart, `values.yaml` and `deploy.sh`, with no
shared code and no cross-folder references. `deploy/cluster/` is the one exception — no
chart and no script, just the manifests that `setup.sh` applies. The documentation is
deliberately centralized — only `AGENTS.md` and `README.md` exist, both at the repo root.

## Infrastructure Assumptions

Everything here is pinned to one node and will not schedule elsewhere. No hostname, IP
address or credential is written in any tracked file: the values that name a machine come
from the gitignored `.env`, so a cloned repository deploys on any site.

| Item | Value |
|---|---|
| Node | single node, named by `K3S_NODE_NAME` in `.env` — the `kubernetes.io/hostname` label from `kubectl get nodes` |
| Data roots | `LIVE_DATA_PATH` and `BACKUP_DATA_PATH` in `.env` — two different paths, default `~/.open-webui/live-data` and `~/.open-webui/backup-data` |
| StorageClass | `local-storage`, provisioner `kubernetes.io/no-provisioner` — created by `deploy/setup.sh` from `deploy/cluster/manifests/` |
| Pre-existing PVC | `open-webui` in `default` — required, **not** created by the chart; also applied by `setup.sh` |
| Postgres DNS | `postgres.default.svc.cluster.local:5432` (user/db/password all from `.env`) |
| NodePorts | Open WebUI `30000`, Postgres `30432` |
| Public URL | `WEBUI_URL` in `.env`; TLS terminated on an external reverse proxy, not in-cluster; K3s is installed with `--disable traefik` |
| Inference | `OPENAI_API_BASE_URL` in `.env`; the endpoint is external to this repo |

The PV nodeAffinity matches the **K3s node name**, which is the `kubernetes.io/hostname`
label — not necessarily what `hostname` prints, and frequently a short name while the OS
hostname is fully qualified. They are two different strings, and a node registered under a
name `K3S_NODE_NAME` does not match leaves every PVC unbound with no useful event.
nodeAffinity is **immutable** on a local PV: changing `K3S_NODE_NAME` against a cluster
whose PVs already exist makes the next `helm upgrade` fail, and correcting it means
deleting and recreating the PV with its data moved aside first.

`local-storage` must stay `kubernetes.io/no-provisioner`. A dynamic local-path
provisioner under that name would satisfy an unmatched PVC with a directory under
`/var/lib/rancher/k3s/storage`: wrong disk, outside every backup, reported Bound and
Healthy.

Host paths, derived from the two `.env` roots and created by `setup.sh` before
install (the paths below use the defaults `~/.open-webui/live-data` and
`~/.open-webui/backup-data`; `LIVE_DATA_PATH` / `BACKUP_DATA_PATH` override them):

- `<LIVE>/postgresql` — Postgres data (owned by UID 70; the pod runs the whole
  container as the image's postgres account — `podSecurityContext` in
  `values.yaml`, with `fsGroup: 70` giving the hostPath volume group ownership
  at mount)
- `<LIVE>/postgresql-backups` — daily `pg_dump` output (owned by UID 70; the
  backup job runs as the same non-root account)
- `<LIVE>/searxng` — SearXNG config and state (owned by UID 977)
- `<LIVE>/open-webui` — the app volume: `uploads/`, `vector_db/` and `cache/`,
  the only copy of user documents and their ChromaDB embeddings, and what the
  uploads CronJob tars. Owned by the user who ran `setup.sh`; the app pod runs as
  that user (`podSecurityContext` injected by `deploy.sh`), so files the app
  writes stay owned by that user, never root
- `<BACKUP>/postgresql` and `<BACKUP>/open-webui` — off-root archives, created
  by the jobs on demand. `<BACKUP>/open-webui` is owned by the deploying user,
  which is who the uploads CronJob runs as

`deploy/setup.sh` builds its `HOST_PATHS` list from the two roots and fails if
any path a deploy script mounts is missing from it; the deploy scripts also
refuse to run if the resolved directories do not exist, pointing at `setup.sh`.

The two roots are site values, so they live in the gitignored `.env` and never
in a tracked file: `values.yaml` carries empty path fields guarded by `required`
in the templates, and `deploy.sh` injects the resolved paths. `deploy/setup.sh`
renders `${LIVE_DATA_PATH}` in the open-webui PV template the same way it
renders `${K3S_NODE_NAME}`.

`LIVE_DATA_PATH` and `BACKUP_DATA_PATH` (the two data roots) must be **different
paths**; the scripts never partition, format or mount, and they accept whatever
the user provides — mount points, plain directories, or bind mounts. Both default
to `~/.open-webui/{live-data,backup-data}`. A single physical device is allowed
with an advisory: `bootstrap-host.sh` prints a `PRODUCTION RECOMMENDATION` warning
when both roots share an `st_dev`, because a disk holding both the data and its
only backup dies together. Changing a root after the first deploy means moving the
data and recreating the local PVs, whose paths are immutable.

**Inference backend** is external to this repo. `.env` carries `OPENAI_API_BASE_URL`,
which `deploy/open-webui/deploy.sh` renders into the container as `OPENAI_API_BASE_URL`.
`ENABLE_PERSISTENT_CONFIG: "true"` means the app's own `openai.api_base_urls` config row
overrides it once an admin has saved endpoint settings in the UI, and that row can hold
several endpoints with no overlap with the chart value. Only listening endpoints return
models; the app logs a connection error for each down endpoint on every model-list
refresh. Read the row, not the chart, when asked what the app is using:
`select value from config where key = 'openai.api_base_urls'`. `setup.sh` probes every
endpoint in both places and reports latency for each.

**Embeddings run in-process** (`RAG_EMBEDDING_ENGINE: ""`, sentence-transformers
`all-MiniLM-L6-v2`). No external embedding API is provisioned — budget roughly 500 MB RAM
per worker.

## Secrets and site values

Every value that names a machine lives in **`.env` at the repo root** — gitignored,
mode `0600`, template in the tracked `.env.example`. **No credential is a `.env`
key.** Every credential lives in one of three pre-created Kubernetes Secrets,
entered once through `deploy/secret-init.sh` and encrypted at rest by K3s
`--secrets-encryption`. The charts reference the Secrets by name
(`existingSecret`); no chart template creates a credential Secret, so helm can
neither render nor rewrite one, and `helm get manifest` prints no credential.

```
.env ─► component deploy.sh (validates the keys it uses, rejects CHANGE-ME) ─► 0600 temp YAML
        ├─ K3S_NODE_NAME ─► persistence.nodeName ─► pv.yaml (guarded by `required`)
        ├─ LIVE_DATA_PATH ─► *.localPath / hostPath / sourcePath ─► pv.yaml, backup CronJobs
        │                    (default ~/.open-webui/live-data; empty in values.yaml, `required`-guarded)
        ├─ BACKUP_DATA_PATH ─► backup.offDisk.hostPath / uploadsBackup.hostPath ─► CronJobs
        │                    (default ~/.open-webui/backup-data; same `required` guards)
        ├─ WEBUI_URL ─────► open-webui.commonEnvVars ─► container env
        └─ OPENAI_API_BASE_URL ─► open-webui.openaiBaseApiUrl ─► container env

secret-init.sh (interactive, prompts on stderr, values piped via 0600 temp files,
        never argv) ─► kubectl create --dry-run=client -o yaml | kubectl apply ─►
        ├─ postgres (key: password)
        ├─ ai-open-webui-secrets (keys: WEBUI_SECRET_KEY, DATABASE_URL,
        │                         optional GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET)
        └─ ai-open-webui-searxng (key: brave-api-key; created only when a key is
                                  given — the chart ref is optional: true)
        └─ fingerprints ─► secrets.manifest (repo root, gitignored; salt + HMAC per
                           key, written AFTER a successful apply; all --check paths
                           recompute it to detect drift/rotation; no value in it)
```

`deploy/secret-init.sh` assembles `DATABASE_URL` itself from the `POSTGRES_*`
values in `.env` plus the prompted password (URL-encoded, password on stdin),
so the DSN and the DB password can never drift apart. The SSO mode is read from
the Secret (`GOOGLE_CLIENT_ID` present or absent), not from `.env`; a half pair
(ID without secret or the reverse) is a hard error. The Brave key shape check
(letters/digits/`-`/`_` only — the init container interpolates it into
`settings.yml`) lives in `secret-init.sh` now.

Missing Secrets fail BEFORE helm: both component `deploy.sh` scripts verify
existence + required keys (`require_secret`) and point at `./deploy/secret-init.sh`;
`setup.sh` does the same (TODO in `--check`, hard refusal in live mode). This
replaces the old `required`-guarded secret templates, which died with the move.

Each script validates its own `REQUIRED_VARS`: the Open WebUI script checks seven
site keys, the Postgres script three `POSTGRES_*` plus `K3S_NODE_NAME`. Both also read `LIVE_DATA_PATH` and
`BACKUP_DATA_PATH` through `resolve_data_root()`, which expands `~`, requires an
absolute path limited to `[A-Za-z0-9._/-]` (the roots are rendered into CronJob
manifests and PV specs, so shell metacharacters and quotes are rejected at this
boundary), and falls back to `~/.open-webui/{live-data,backup-data}` when the
key is empty; neither is in `REQUIRED_VARS` because empty is valid (the default
applies), but the deploy scripts refuse to run if the resolved directories do not
exist on the host, pointing at `setup.sh`.
`deploy/deploy.sh` checks that `.env` exists and leaves the rest to the component scripts.

`WEBUI_URL`, `ENABLE_LOGIN_FORM` and the three `WEBUI_*_COOKIE_*` vars reach the
container through `commonEnvVars` with a deliberate reason: Helm **replaces** a
list rather than merging into it, so injecting one entry into `extraEnvVars`
would erase the long list in `values.yaml`. Those four names therefore live only
in the rendered `commonEnvVars`, never in `extraEnvVars` — a duplicate env name
fails at the API server. `ENABLE_LOGIN_FORM` and the cookie `Secure` flags are
computed there: login form on when the Secret has no Google pair (the deploy
reads the Secret, not `.env`), secure cookies on when `WEBUI_URL` is `https://`.
The upstream chart emits its own
`WEBUI_URL` only when ingress or an OpenShift route is enabled, and both are off, so the
container gets exactly one. Enabling ingress alongside `WEBUI_URL` in `.env` produces a
duplicate env name the API server rejects.

`DATABASE_URL` is assembled by `deploy/secret-init.sh` (see above), not by a
deploy script, and it is URL-encoded so a special character cannot corrupt the
DSN. A deploy never sees the password.

**Capacity and scale profiles.** Four keys in `.env` govern resource allocation:
`MESSAGE_SCALE` (`small`, `medium`, `large`) and the host capacity minimums
`DEPLOY_CPU_CORES`, `DEPLOY_MEMORY_GB`, `DEPLOY_STORAGE_GB`.
Both component scripts define a byte-identical profile table (verified by `selftest.sh`)
that calculates:
- CPU/memory requests and limits for all five workloads (`open-webui`, `postgresql`,
  `searxng`, `redis`, and both backup CronJobs).
- Concurrency env vars (`UVICORN_WORKERS`, `DATABASE_POOL_SIZE`,
  `DATABASE_POOL_MAX_OVERFLOW`) rendered into `commonEnvVars` to avoid list replacement
  and duplicate env errors.
- PostgreSQL `-c` flags (`max_connections`, `shared_buffers`, `effective_cache_size`,
  `work_mem`, `maintenance_work_mem`, `max_wal_size`) rendered into the container `command`.
Declared host resources are checked as minimums at deploy time; choosing a profile the
host cannot carry fails with the exact shortfall.

The entry-point script and both component scripts refuse to run if `.env` is missing,
git-visible, or incomplete.
Never move a credential into `values.yaml`, a template, or `.env`: a committed value
stays in git history even after you delete the line, and a `.env` credential defeats
the Secrets-at-rest model. Credentials belong to `secret-init.sh` and the K3s
datastore only.

## Deployment Commands

`deploy/setup.sh` is the first-time entry point and `deploy/deploy.sh` is the
steady-state one.

```bash
./deploy/setup.sh --check       # report every prerequisite finding; changes nothing
./deploy/setup.sh               # checks, host paths, primitives, .env, then deploy.sh
./deploy/setup.sh --no-deploy   # everything except the helm deploy
```

`setup.sh` is idempotent and creates nothing it did not find missing. It resolves
`K3S_NODE_NAME` from `.env`, falling back to the cluster's only node, resolves the two
data roots (`LIVE_DATA_PATH` / `BACKUP_DATA_PATH`, default `~/.open-webui/{live-data,
backup-data}` — read-only here; the wizard in `bootstrap-host.sh` owns prompting for
them), creates the two data roots (owned by the invoking user) and every host
path `HOST_PATHS` names with the right owner, renders the PV template with the node
name and the live root, and applies both cluster primitives. It generates `K3S_NODE_NAME`
when absent, and **never prompts for any other key** — missing site values fail with
the list and a pointer to `./deploy/bootstrap-host.sh`, the repo's single `.env`
wizard. It also verifies the credential Secrets in-cluster (phase 5): a missing
Secret or key is a TODO in `--check` and a hard refusal with a pointer to
`./deploy/secret-init.sh` in live mode. It deliberately will not install
packages, partition disks, install K3s, or change the ownership of a directory that
already exists — it reports those instead, because they are host decisions with blast
radius beyond this repo. The host-path writability test treats uid 0 as always writable,
which is what CAP_DAC_OVERRIDE means; the per-component container users differ (Postgres
and its backup job run unprivileged at uid 70, SearXNG at uid 977; the open-webui app and
its uploads backup job run as the user who deploys, whose uid `deploy.sh` injects into
both). `setup.sh` itself refuses to run as root: that is how the data tree ends up
root-owned, and root work belongs to `bootstrap-root.sh`.

`deploy/deploy.sh` is the entry point after a change. It deploys PostgreSQL first — Open
WebUI connects to it during startup — then Open WebUI, and ends with a status block for
the whole stack.

```bash
./deploy/deploy.sh                      # postgresql, then open-webui
./deploy/deploy.sh --dry-run            # lint and render both; changes nothing
                                       # on the cluster; Secrets withheld
./deploy/deploy.sh --check              # .env drift for both, in one run
./deploy/deploy.sh open-webui           # one component only
./deploy/deploy.sh postgresql --check   # one component, one mode
./deploy/deploy.sh --pinned             # values.yaml pins even on a fresh install
```

**Fresh-install version policy.** With no release on the cluster, each component
`deploy.sh` resolves the newest GA image tags from Docker Hub / GitHub and passes them
as `--set` overrides; once a release exists, deploys follow `values.yaml` pins exactly
(a steady-state upgrade must be reproducible and reviewed). `--pinned` opts out of the
float; an unreachable registry falls back to the pin with a printed note and never
fails the deploy. The bundled chart version never floats: there is deliberately
no `Chart.lock` — every dependency `version` in `Chart.yaml` is an exact pin and
`helm dependency build` has nothing to re-resolve (selftest.sh fails if a pin is
ever loosened to a range). A newer GA chart is only reported; taking it is a
one-line edit to that `version:` value, which the next deploy pulls. Because the float bypasses `values.yaml`, a fresh install
legitimately runs images whose tags differ from the pins — that is not pin/appVersion
drift to "fix"; the check-updates gate compares pins against files, not the cluster
against the registry.

Target and mode may be given in either order. An unknown argument, or two conflicting
targets or modes, exits 2: the default path is a live deploy, so a mistyped `--dry-run`
must not silently become one. In deploy mode the run stops at the first component that
fails, since deploying the app against a broken database only moves the failure
downstream. `--check` and `--dry-run` cover every selected component and exit 1 if any of
them failed.

The per-component scripts are the primitives. Call one directly when you are working on a
single chart and want its output on its own.

Always `cd` into the chart directory before running helm. Running `helm upgrade` from a
sibling chart's directory causes cross-chart resource collisions. Add `--force-conflicts`
if a prior `kubectl patch` claimed field ownership (typical error:
`conflict with "kubectl-..." ... ENABLE_LOGIN_FORM`).

### PostgreSQL (`deploy/postgresql/`)

```bash
cd deploy/postgresql
./deploy.sh                                 # loads .env, lints, deploys, verifies auth
./deploy.sh --dry-run
./deploy.sh --pinned                        # fresh install: deploy the pin, not newest GA
./deploy.sh --check                         # .env vs release auth.*, persistence.*
                                            # and backup.* paths, and vs the credential
                                            # Secret + secrets.manifest fingerprints
helm lint .
helm template postgres . > rendered.yaml    # errors: pv.yaml refuses an empty
                                            # persistence.nodeName or localPath,
                                            # and the templates refuse an empty
                                            # auth.existingSecret
                                            # rendered.yaml is gitignored
helm uninstall postgres -n default          # PV is Retain: data survives
```

Use `./deploy.sh` rather than a bare `helm upgrade`: the node name and the data
paths come only from `.env`, and the chart does not create the password Secret
(it references `auth.existingSecret`), so a raw upgrade with no values file
refuses to render — `templates/pv.yaml` rejects an empty `persistence.nodeName`
or `persistence.localPath`, the deployment and backup CronJob templates reject an
empty `auth.existingSecret`, and `templates/backup-cronjob.yaml` an empty
`backup.hostPath`. `./deploy.sh` additionally refuses to run when the `postgres`
Secret is missing or holds no `password` key, pointing at `./deploy/secret-init.sh`.

### Open WebUI (`deploy/open-webui/`)

```bash
cd deploy/open-webui
./deploy.sh                 # loads .env, builds deps from Chart.yaml pins, lints, deploys, verifies
./deploy.sh --dry-run
./deploy.sh --pinned        # fresh install: deploy the pins, not newest GA
./deploy.sh --check         # every key a deploy would write, compared by value vs .env
helm lint .                 # works without .env; each missing `required` value is a WARN

helm dependency build       # installs exactly the versions Chart.yaml pins —
                            #   deploy.sh runs this itself. There is no
                            #   Chart.lock and no `dependency update` step:
                            #   bump by editing the version in Chart.yaml.
```

`helm template` without values fails on purpose: each `pv.yaml` guards
`persistence.nodeName` and `persistence.localPath`, and the backup CronJobs guard
their hostPaths — so a value-less render errors instead of emitting a PV no node
can bind or a backup job writing to an empty path. Credentials are not chart
values any more: the templates reference the pre-created Secrets by name
(guarded by `required` on `existingSecret` / `extraEnvFrom`'s target). Read the
lint output instead, which reports the same gaps as warnings.

**Do not run a bare `helm upgrade ai-open-webui . -n default`.** Helm merges values per
key, so anything left out silently resets. The credentials are immune now — they
live in pre-created Secrets helm never renders — but the site values are not: a
raw command with no values file resets `searxng.persistence.nodeName` /
`localPath` (empty `existingSecret`-style `required` guards make some of these
fail loudly, but not all), `uploadsBackup.*` paths, and the profile sizing in
`commonEnvVars`. If you must use raw helm, pass a values file carrying
`searxng.persistence.nodeName`, `searxng.persistence.localPath`,
`uploadsBackup.sourcePath`, `uploadsBackup.hostPath`, `open-webui.openaiBaseApiUrl`
and `open-webui.commonEnvVars`.

There is no `Chart.lock` in this repo: `Chart.yaml` carries exact `X.Y.Z` pins for every
dependency, so `deploy.sh` runs plain `helm dependency build` and a Chart.yaml edit takes
effect on the next deploy with no lock to re-resolve (a stale lock used to be a footgun
here, not a safety net — selftest.sh enforces the exact-pin policy in the lock's place).
`charts/*.tgz` are gitignored build artifacts that `deploy.sh` regenerates.

## Verification One-Liners

```bash
./deploy/selftest.sh                                          # pure-shell self-check:
                                            # path/identifier validators, the
                                            # backup-CronJob injection guards, and
                                            # .env key wiring; no cluster needed
kubectl get pods -n default                                   # 1/1 Running, 0 restarts
helm status ai-open-webui -n default
helm status postgres -n default

curl -s -o /dev/null -w "%{http_code}\n" http://localhost:30000/health     # 200
curl -s http://localhost:30000/api/config | python3 -c "import sys,json;print(json.load(sys.stdin)['version'])"
kubectl exec -it deploy/postgres -n default -- psql -U openwebui -d openwebui -c "\dt"

SVC=$(kubectl get svc ai-open-webui-searxng -n default -o jsonpath='{.spec.clusterIP}')
curl -s --max-time 20 "http://$SVC:8080/search?q=test&format=json" \
  | python3 -c "import sys,json;print(len(json.load(sys.stdin)['results']),'results')"

# Backups: a Complete job is not proof the archive restores — read the gate lines.
kubectl get jobs -n default -o wide
kubectl logs -n default -l app.kubernetes.io/component=backup --tail=15 --prefix
kubectl logs -n default -l app.kubernetes.io/component=uploads-backup --tail=5 --prefix
ls -lh "$BACKUP_DATA_PATH"/postgresql "$BACKUP_DATA_PATH"/open-webui   # from .env
```

Do not trust `kubectl get pods` alone as proof the app is serving: confirm the image, the
`/health` code, and `/api/config`. Use `app.kubernetes.io/component=open-webui` for logs;
`app=open-webui` matches nothing.

## Git Workflow

Everything is in this repo on `main`; no submodules.

```bash
git pull
git checkout -b <branch>     # or commit on main
git add <paths> && git commit -m "..." && git push
```

## Working Conventions

- Investigate existing charts and templates before changing anything; the chart sections
  below hold the detail for each deployment.
- Follow the existing patterns in `values.yaml` and templates.
- Do not put an app or chart version number in a `values.yaml` or template comment. The
  pins move constantly, and a stale "version X does not support this" reads as verified
  fact long after it stops being true. Write "the pinned image" instead and give the
  command that actually checks the claim, for an env var name that is:
  `kubectl exec -n default statefulset/ai-open-webui -c open-webui -- grep -rn
  "NAME" /app/backend/open_webui --include=*.py`. Versions belong in `Chart.yaml` and the
  image tags in `values.yaml`, which are the only places a version is authoritative.
- Plan, then act, then validate with `./deploy/selftest.sh` (pure-shell checks, no
  cluster needed), `helm lint` and `./deploy/deploy.sh --dry-run` before a live deploy.
- Deploy with `./deploy/deploy.sh`. Do not invent a helm command line for a normal deploy:
  the site values come from `.env` through the component scripts, which also verify the
  credential Secrets first.
- **README.md documents behaviour; keep it in step.** Any change to what a script asks,
  checks, writes, or deletes must update the matching README section in the same change —
  the README is the single human-facing guide, and a stale paragraph reads as verified
  fact. The same rule covers this file's chart sections: they are the agent-facing
  counterpart and go stale the same way. Map for README updates:

  | What changed | Update in README.md |
  |---|---|
  | `bootstrap-host.sh` wizard keys or validators | "What the wizard asks" |
  | `secret-init.sh` prompts, Secret names/keys, the fingerprint manifest | "Where the credentials live" (incl. the rotation note) |
  | `deploy.sh` modes, flags, profile behaviour | "Everyday commands" |
  | `setup.sh` phases, host-path ownership, container uids | "How it works" (the four rules) and "Troubleshooting" |
  | backup/restore/uninstall behaviour, CronJob schedules, gates, retention | "Backups and restore" (both layers) and the "Troubleshooting" table |
  | login or SSO behaviour | "Login options" |
  | version pin or float policy | "Upgrades" |

  Two cheap consistency checks beyond re-reading: no credential may appear as a `.env`
  key — `grep -n 'POSTGRES_PASSWORD\|OPEN_WEBUI_SECRET_KEY\|BRAVE_SEARCH_API_KEY'
  README.md` must return nothing (those names are Secret labels only) — and one section
  must not contradict another: the nightly-archives table and the bundle section have to
  agree on what the nightly layer actually covers.
- Read the `Open WebUI Chart` and `PostgreSQL Chart` sections of this file, plus the
  architecture, backup and restore sections of [README.md](./README.md), before editing
  values or templates.

## PostgreSQL Chart (`deploy/postgresql/`)

### Architecture

- **fullname helper**: `_helpers.tpl` returns just `{{ .Release.Name }}`, which is why the
  release name **must** be `postgres` — that keeps DNS at
  `postgres.default.svc.cluster.local:5432`.
- **Image**: official `postgres:19.0-alpine`, pinned to the patch release in `values.yaml`.
  The same tag drives both the Deployment and the `postgres-backup` CronJob. Single
  replica, `Recreate` strategy.
- **Postgres runs non-root.** `podSecurityContext` in `values.yaml` pins the server pod
  **and** the backup CronJob (`backup.podSecurityContext`) to uid/gid 70 — the
  `postgres:*-alpine` image's postgres account — with `runAsNonRoot: true` as the
  fail-visible guard and `fsGroup: 70` to give the hostPath volumes group ownership at
  mount (the kubelet, not the container, does that chown). This is the same hardening
  shape SearXNG carries: `runAsNonRoot` is the part doing the work, so deleting
  `runAsUser` breaks the rollout loudly instead of quietly restoring root. The host
  directories setup.sh creates for these pods are `70:70` accordingly.
- **Persistence**: local PV pinned by `nodeAffinity` to `K3S_NODE_NAME` from `.env`, at
  `LIVE_DATA_PATH`/postgresql (default `~/.open-webui/live-data/postgresql`),
  StorageClass `local-storage`, reclaim policy `Retain` —
  data survives `helm uninstall`. `persistence.nodeName` and `persistence.localPath`
  are empty in `values.yaml` and filled by `deploy.sh` from `.env`;
  `templates/pv.yaml` refuses to render without either.
- **Backup**: daily CronJob at 02:00 UTC dumps every database listed in `backup.databases`
  (`openwebui` here — list only databases that exist, see gotchas) to `<LIVE>/postgresql-backups/`, then copies each
  verified archive to `backup.offDisk.hostPath` (the second path). Each archive goes
  through four gates before it counts: `gzip -t`, the `PostgreSQL database dump complete`
  trailer, a **restore into the `restore_verify` scratch database** compared against the
  live table inventory, and a re-check of the off-disk copy. The script runs under
  `set -euo pipefail` because `pg_dump`'s exit status sits behind the pipe to `gzip`: with
  plain `set -e` a failed dump returns gzip's success, the job reports success, writes an
  empty archive, and retention then deletes a good backup to make room for it. A `psql`
  call needs `PGPASSWORD` exported — it does not read `POSTGRES_PASSWORD` — and psql with
  no password on a job with no tty fails at the prompt.
- **Retention counts days, not files.** `backup.retentionCount` is a number of distinct
  days, and several archives may share one. Counting files made hand-run jobs a
  eviction risk: three manual runs in one morning consumed the whole budget and deleted a
  week of nightly archives, leaving the RPO at hours. Anything that fails verification is
  deleted rather than kept as a restore point that does not exist. `backoffLimit: 1`
  keeps a persistent failure from writing a fresh set of archives per retry. Both backup
  CronJobs set `startingDeadlineSeconds` (3600): a CronJob with no deadline is **skipped**,
  not deferred, when the node is down at the scheduled minute, and `kubectl get jobs` goes
  on reporting success while the newest archive ages out of the retention window.
- **`extraDatabases`**: provisions extra databases and users through init scripts, which
  run only on first data-directory creation. Adding entries later needs manual `psql` or a
  PV re-initialization.
- **Performance tuning**: pass `-c` flags to the `postgres` binary via the `command`
  override in `values.yaml`. `command` replaces the image ENTRYPOINT, so it must start
  with `docker-entrypoint.sh` the way the commented example in `values.yaml` does: a
  `command` that begins with `postgres` skips initdb entirely and never runs
  `/docker-entrypoint-initdb.d`, so `extraDatabases` silently stops being created. The
  `POSTGRES_MAX_CONNECTIONS` and
  `POSTGRES_SHARED_BUFFERS` env vars have no effect.

### Gotchas

- The password lives only in the pre-created `postgres` Secret (`auth.existingSecret`
  in `values.yaml`; `auth.password` does not exist). It is honoured only while
  initialising an empty data directory, so re-running `secret-init.sh` later rewrites
  the Secret while the database keeps the old credential. Rotate with `ALTER USER` in
  psql first, then re-run `./deploy/secret-init.sh` (re-enter or regenerate), then
  restart the Open WebUI pod — editing a Secret's contents leaves the pod template
  untouched, so no rollout happens and the container keeps the old env.
  `secrets.manifest` records the new fingerprint on the next secret-init run; until
  then every `--check` reports drift, which is the point.
- Postgres runs as UID 70 end to end — server pod and backup CronJob both pin
  `runAsNonRoot`/`runAsUser: 70` via `podSecurityContext` in `values.yaml`, so the image
  entrypoint never starts as root and never needs to chown. The **host** paths
  `<LIVE>/postgresql`, `<LIVE>/postgresql-backups` and `<BACKUP>/postgresql` must
  therefore be writable by UID 70, which is how `deploy/setup.sh` evaluates them
  (created `70:70`; a pre-existing root-owned directory is rescued at mount by
  `fsGroup: 70`, but setup.sh will still ask for `sudo chown 70:70` — do it).
  Deleting `runAsUser` must fail the rollout, not restore root: `runAsNonRoot: true` is
  what makes that happen, the same guard SearXNG carries. What CrashLoopBackOffs is a
  parent uid 70 cannot write.
- Any database outside `extraDatabases` has no coverage unless it is named in
  `backup.databases`, and `backup.databases` must list **only databases that exist** — a
  missing one fails the whole run even when every other dump verified. `localai` was on the
  original server (owner role `localai`, never declared, dumped only because it was added to
  the list) but `extraDatabases` is empty here, so the entry was removed; add it back only
  after the database exists. The dump works because the
  `openwebui` role holds `rolsuper` — remove that privilege and cross-database dumps stop
  working, so change the two together.
- Major-version upgrades (17 → 18) need dump/restore: the image refuses to open a data
  directory from another major. Move the old data aside, let the new pod initdb, then
  restore. A `pg_dump --no-owner` dump drops ownership, so re-apply `OWNER TO` afterwards.
- `deploy.sh` verifies auth by connecting over the Service FQDN. Keep it that way:
  `pg_hba.conf` grants `trust` to `127.0.0.1/32` and `::1/128`, so a loopback `psql`
  accepts any password, including an empty one, and the check would pass while every real
  client was being rejected.

### Troubleshooting

- **Pod CrashLoopBackOff**: check `<LIVE>/postgresql` (the Postgres data dir from
  `LIVE_DATA_PATH`) exists and is writable by UID 70 — the pod is fully non-root
  (see the UID 70 note under Gotchas). `./deploy/setup.sh --check` reports the owner.
- **Connection refused from another pod**: verify the PVC is `Bound` and service DNS resolves.
- **Extra database missing after a `values.yaml` edit**: init scripts only run on an empty
  data directory.
- **Backup missing**: ensure `<LIVE>/postgresql-backups` exists; the off-disk
  directory under `<BACKUP>` is created by the job. Read the job's log —
  `kubectl logs job/<name> -n default` — which names the gate that failed: dump, trailer,
  restore comparison, or off-disk copy. A `restore_verify` database left behind means
  the last run failed mid-verification; the next run drops and recreates it.

## Open WebUI Chart (`deploy/open-webui/`)

### Architecture

```
deploy/open-webui/   ← root chart
├── Chart.yaml           ← declares two dependencies
├── values.yaml          ← overrides for both subcharts, uploadsBackup:, the
│                          extraEnvFrom reference to the pre-created ai-open-webui-secrets
├── templates/
│   └── uploads-backup-cronjob.yaml
├── charts/
│   ├── searxng/         ← local subchart (tracked source, custom)
│   └── open-webui-*.tgz ← upstream chart (packaged, gitignored)
```

- **`searxng`** — local subchart at `charts/searxng/`, managed in this repo; owns its
  Deployment, Service, PV and PVC. An **init container** rewrites `settings.yml` to the
  persistent volume from the chart's heredoc on **every** pod start, so the config always
  matches the template and no PV reset is needed after an image upgrade. Engine changes made
  in the SearXNG UI are lost on restart — persist them in
  `charts/searxng/templates/deployment.yaml`. Persistence is a `local` PV pinned by
  `nodeAffinity` to `K3S_NODE_NAME` from `.env`, at `<LIVE>/searxng`; the PV
  name is `<release-name>-searxng-pv` and the PVC binds to it by `volumeName`. Outbound
  request
  timeout is **15s** (raised from the 1.5s default). The `google` HTML scraper is
  `disabled: true` in the heredoc — it is bot-blocked from this node — while `bing`,
  `google cse` and `braveapi` serve default queries. (The `google cse` engine is
  not explicitly enabled in the heredoc — it needs its own API key, so `bing`
  and `braveapi` are the ones that actually answer.)
- **SearXNG runs unprivileged.** `podSecurityContext` in `charts/searxng/values.yaml` sets
  `runAsNonRoot` with uid/gid 977, the `searxng` account inside the image, plus
  `seccompProfile: RuntimeDefault`; both containers drop all capabilities and set
  `allowPrivilegeEscalation: false`. The host path is already owned by 977:977, which is
  what lets the init container keep rewriting `settings.yml`. `runAsNonRoot` is the part
  doing the work: the kubelet refuses to start the pod if the image would run as root, so a
  regression fails the rollout visibly. This is the component that parses untrusted HTML
  from the internet, which is why it carries the full hardening; the app and its
  backup job are non-root for ownership reasons (below), not because they parse
  untrusted input.
- **`open-webui`** — upstream chart from `https://helm.openwebui.com/`, version pinned in
  `Chart.yaml` (`helm show chart charts/open-webui-*.tgz` is the only authoritative
  readout), downloaded on demand by `helm dependency build`. The
  chart's `appVersion` can lag the image pinned in `values.yaml`, which is expected since
  the app image and the chart are released separately.
- **The app runs unprivileged as the deploying user.** `deploy.sh` renders
  `open-webui.podSecurityContext` (`runAsNonRoot` plus the uid/gid of whoever runs the
  deploy) and `containerSecurityContext` (all capabilities dropped, no privilege
  escalation) — the same fail-visible shape as the postgres and SearXNG pods. This is
  what keeps `<LIVE>/open-webui` owned by the operator over time: a root container
  writes root files. Two consequences: the in-process embedding model downloads at
  runtime, so its Hugging Face cache is pinned onto the data volume with `HF_HOME`
  (root's home is not writable for that user, and the volume is where the cache persists
  and is backed up); and the uploads backup CronJob runs as the same user with every
  capability dropped, including the `DAC_OVERRIDE` it carried while the app ran as root.
- **Open WebUI config** (root `values.yaml`): NodePort `30000`; login is Google OAuth
  when the `ai-open-webui-secrets` Secret carries the `GOOGLE_CLIENT_ID` /
  `GOOGLE_CLIENT_SECRET` pair, else the built-in login form (`ENABLE_LOGIN_FORM` is
  computed by `deploy.sh` from the Secret — see Secrets and site values).
  `DEFAULT_USER_ROLE: pending` applies to everyone **except the first account**, which the
  app's first-user bootstrap promotes to admin on its first login regardless of that
  default (`utils/oauth.py` returns `admin` when `user_count == 1`, and promotes after
  insert via `get_num_users() == 1`). So the first person to sign in — OAuth or form — owns
  the instance; sign in immediately after the first deploy, and treat the URL as
  admin-granting until you have. Later signups are `pending` until approved in Admin
  Settings → Users. Persistence on the pre-created `open-webui` PVC.
  Credentials arrive through the
  `ai-open-webui-secrets` Secret (pre-created by `secret-init.sh`) and `extraEnvFrom`,
  never the inline `env` list, which keeps them out of the pod spec. The Secret is NOT
  part of the release: `helm get manifest` prints no credential, and an upgrade can
  neither rewrite nor delete it. `--dry-run` still runs helm with `--hide-secret` as
  belt and braces.
  `WEBUI_URL` and `openaiBaseApiUrl` are empty in `values.yaml` and filled from `.env`,
  because both name this installation: the public hostname and the inference host.
- **`uploadsBackup`** (root `values.yaml`) — a CronJob at 02:30 UTC tars the whole
  `open-webui` volume to `<BACKUP>/open-webui`, keeping
  `retentionCount` days. `uploads/` and `vector_db/` hold the only copies of user
  documents and their ChromaDB embeddings, and the Postgres CronJob dumps databases only,
  so nothing covered this volume before it existed. `cache/` is included: it is
  rebuildable, and guessing which of the three subtrees is safe to drop is a worse failure
  than a bigger archive. The job runs as the deploying user (the same uid `deploy.sh`
  gives the app pod) with **every** capability dropped — including the `DAC_OVERRIDE`
  it carried while the app ran as root and left files tar could not read. Its pod carries
  `app.kubernetes.io/component: uploads-backup` and never the open-webui label set, which
  would put it in the app Service's endpoints. Alpine's busybox `tar` has no
  `--warning=no-file-changed`: it answers with its usage text and exit 1, so correctness
  rests on the `gzip -t`, `tar -t` and member-count checks instead of tar's exit status.
  Unlike the Postgres job it does **not** restore an archive into a scratch location, so
  `tar -t` proves readability, not that extraction yields a usable volume. It carries the
  same `startingDeadlineSeconds: 3600` as the Postgres job for the same reason.
- **`ollama.enabled` and `pipelines.enabled`** are read from the **parent** chart's
  `open-webui:` block. The bundled chart's own `values.yaml` defaults both to `true`, so
  deleting those lines silently re-enables Ollama.
- **`ENABLE_PERSISTENT_CONFIG: "true"`** means the app's own `config` table can shadow
  values set in `values.yaml`. When a setting looks ignored, check the database. The
  running process loads that table once at startup and refreshes it only through the API,
  so a hand-run `update config ...` in psql changes **nothing** until the pod restarts:
  pair a direct edit with a rollout, or make the change in Admin > Settings. Tags live in
  `chat.meta.tags`; `chatidtag` is an unused legacy table, so counting it reports 0 and
  proves nothing about whether tag generation is used.
- **Runtime pip installs land on the PVC, not the container layer.** The app pip-installs
  document-loader packages it lacks at first use; `PIP_TARGET` and `PYTHONPATH`
  (extraEnvVars in the parent `values.yaml`) redirect those onto the data volume at
  `pip-extras/`, and the upstream chart's built-in `copy-app-data` init container — whose
  `copyAppData.command` the parent overrides — prewarms the same path from a literal
  `PKGS=""` list. Three couplings to remember: the three path references must agree
  (selftest checks the two env vars), the overridden `cp -R -n` line replicates the
  bundled chart's current default (check it when bumping the chart), and `PYTHONPATH`
  **shadows** the image's bundled packages — never preload a package the image already
  ships at a different version.

### Probes

The upstream chart ships `startupProbe`, `readinessProbe` and `livenessProbe` as `{}` —
disabled — which makes the pod report `1/1 Running` the moment the container starts,
including while alembic is still migrating with nothing listening. `values.yaml` sets all
three:

- `startupProbe` on `/health`, 10s period, `failureThreshold: 60` — a ~10 minute migration
  window. Keep it generous so a long migration is never killed.
- `readinessProbe` on `/health/db`, 10s period, 6 failures — keeps traffic off a pod whose
  database is unreachable.
- `livenessProbe` on `/health`, 10s period, 6 failures — counts only after the startup
  probe passes.

Both endpoints return `{"status":true}`. With these enabled, `kubectl rollout status` and
`kubectl get pods` become meaningful during an upgrade. Do not remove them.

SearXNG carries the same three probes, defined in `charts/searxng/values.yaml` and
rendered by `charts/searxng/templates/deployment.yaml`, against its own `/healthz`, which
answers `200 OK` when serving and `404` for any other path. Without them the pod reports
Ready the moment the container starts, so the `kubectl rollout status deploy/...-searxng`
wait in `deploy/open-webui/deploy.sh` returns before SearXNG can answer a query. The init
container pins `imagePullPolicy` explicitly too: it runs the same image and writes the
`settings.yml` the main container reads, and an omitted field would default it to
`IfNotPresent` while the main container pulls `Always`.

The bundled Redis image is overridden under
`open-webui.websocket.redis.image.tag`; the bundled chart's own default is an older
major line. Read both from the files rather than trusting this sentence:
`helm show values deploy/open-webui/charts/open-webui-*.tgz | grep -A2 'redis'`.

### Troubleshooting

- **`helm lint` or `helm template` fails with missing dependency**: run
  `helm dependency build`, which installs exactly what the `Chart.yaml` pins
  name. There is no lock file and no `helm dependency update` step.
- **PVC pending**: the usual cause is the node name, not the StorageClass — static
  binding succeeds on a matching `storageClassName` even when no StorageClass object
  exists, so `local-storage` being absent is not the problem. Compare
  `kubectl get nodes -o wide` and the `kubernetes.io/hostname` label against the
  `nodeAffinity` in the PV. Then check the host directory exists: a `local` PV whose
  path is missing cannot bind. `./deploy/setup.sh --check` reports both.
- **SearXNG serving the wrong config**: the init container regenerates `settings.yml` on
  every pod start, so fix `charts/searxng/templates/deployment.yaml` and restart the pod.
  Clearing `<LIVE>/searxng` is not required.
- **`CreateContainerConfigError`**: the `ai-open-webui-secrets` Secret is missing a key —
  re-run `./deploy.sh`.
- **`helm upgrade` fails with `conflict with "kubectl-..." ... ENABLE_LOGIN_FORM`**: re-run
  with `--force-conflicts`.
- **One container restart on a fresh database**: with `UVICORN_WORKERS` (3 in the small
  profile), all workers race to seed the default `config` rows at first start; the loser
  hits
  `IntegrityError ... config_pkey1`, aborts, and the uvicorn parent exits cleanly
  (exit 0). The kubelet restarts the container and the second start is clean because
  the rows already exist. It lands inside the startup-probe window, before the pod is
  Ready, so it is invisible to users; no action is needed. The same error recurring on
  a warm database would be a different bug — check the `config` table.

## Reference Documents

- `deploy/bootstrap-root.sh` — the host installer, **the only script that changes the
  host; run it with sudo**: apt packages, kernel modules + modules-load, sysctl keys,
  swap-off (the kubelet refuses to start with swap), K3s (`--disable traefik
  --secrets-encryption --node-name`), helm v4. Idempotent; `--check` changes nothing;
  `--no-k3s` / `--no-helm` skip installs. Never partitions, formats or mounts.
- `deploy/bootstrap-host.sh` — the main entry point for a fresh machine, **run as a
  normal user**: validates every host item (packages, modules, sysctl, swap, k3s, helm
  v4) and prints the single `sudo .../bootstrap-root.sh` command for anything missing,
  then runs the **.env wizard that prompts for every site value, validates each answer
  before accepting it, and stores it in `.env` immediately** (the two data paths
  default to `~/.open-webui/{live-data,backup-data}` and Enter accepts). It asks for
  no credential. Before handing off to `setup.sh` it checks the credential Secrets:
  on a fresh install (none exist yet) it stops with the one remaining command,
  `./deploy/secret-init.sh`. `--check` changes nothing; `--no-setup` stops before the
  handoff; `--configure` re-asks keys that already hold a valid value. On an
  already-provisioned host, `setup.sh` is still the direct entry point.
- `deploy/secret-init.sh` — one-time credential entry: prompts on stderr (stdout
  carries values), assembles `DATABASE_URL` from `.env` `POSTGRES_*` + password,
  applies the three Secrets via `--dry-run=client | kubectl apply`, records an
  HMAC fingerprint per key in `secrets.manifest` (gitignored, written after the
  apply), and refuses argv-carried values (`--from-file` only). `--check` verifies
  existence, required keys, and fingerprint drift, changing nothing.
- `deploy/setup.sh` — the first-time entry point; its header comment documents the modes
  and what it refuses to do
- `deploy/deploy.sh` — the single entry point for deploying; its header comment documents
  every target and mode
- `deploy/backup.sh` — portable encrypted backup: one GPG-symmetric (AES256) bundle with
  the site-value `.env`, every credential Secret (`secrets.env`, base64 per key under a
  `#secret <name>` header), the fingerprint manifest, a `pg_dump` per database, and both
  volumes (`open-webui`, SearXNG), round-trip verified before it is handed over — the
  verification recomputes every fingerprint from the decrypted values, so the dump is
  proven bit-exact; `--dest` (not under `LIVE_DATA_PATH`) and
  `--passphrase-file` (mode 0600) for scripted runs
- `deploy/restore.sh` — decrypts and verifies a backup bundle, installs its `.env` (the
  node name is forced to this server's, since local PVs pin it), rebuilds the credential
  Secrets from the bundle's `secrets.env` (fingerprint-verified) and installs
  `secrets.manifest`, runs `setup.sh` or `deploy.sh`, recreates each database from its
  dump, extracts the volumes, and verifies `/health` plus the chat row count against the
  manifest; refuses to bootstrap the host
- `deploy/uninstall.sh` — the staged uninstall: a stage-0 encrypted-backup offer, then
  releases, cluster objects (stage 2 also deletes the three helm-unowned credential
  Secrets), host data (stage 3 also deletes `.env` and `secrets.manifest`), and the
  host itself; one arithmetic gate at
  the start of the run (three tries, before the first pending stage), and
  no `--yes`, stage 3 names every previous backup it deletes, and stage 4 removes an
  apt package only if nothing installed depends on it (apt's dry-run decides) and it is
  not one the repo's own scripts need (`REPO_TOOLING_PKGS`, currently `python3`)
- `deploy/selftest.sh` — the no-cluster regression test: extracts the live validators
  from the deploy scripts (never re-implements them), asserts the backup CronJob bodies
  interpolate nothing from `.env`, checks the `.env` key wiring across the files that
  must agree (and that no credential is a `.env` key anywhere), and asserts the
  credential architecture (no chart-owned Secret template, `existingSecret` refs,
  `--from-file` never `--from-literal`, fingerprints recorded after apply, SSO mode
  from the Secret, backup/restore/uninstall handle `secrets.env` and the Secrets).
  Run it after touching any validation logic.
- `deploy/smoke-test.sh` — the layered no-browser health check a user runs to
  confirm a deployment works: tier 1 selftest + `helm lint` + chart render,
  tier 2 the three `--check` modes, tier 3 pods/releases/PVC binding and the
  `local-storage` no-provisioner guard, tier 4 `/health` + `/health/db` +
  version + inference reachability, tier 5 SearXNG results plus (with
  `SMOKE_API_KEY` in the environment, never argv) a real chat completion via
  `/api/chat/completions`, tier 6 manual runs of both backup CronJobs judged by
  their gate lines and the archives on disk. Read-only except creating and
  deleting its two manual jobs; `--quick` / `--no-backup` skip the slow tiers;
  exit 1 on any failure. It does not replace the browser checks in README's
  "Check that it works".
- `deploy/cluster/manifests/storageclass.yaml` — the `local-storage` StorageClass,
  `no-provisioner` by design
- `deploy/cluster/manifests/open-webui-volume.yaml.template` — the `open-webui` PV/PVC no
  chart owns; `setup.sh` substitutes the node name and `LIVE_DATA_PATH` and pipes it to
  `kubectl`, so applying it with `kubectl -f` directly leaves the PVC Pending
- [README.md](./README.md) — the single human-facing guide: hardware, OS, K3s, API keys
  with acquisition steps, deploy, verification, restore, day-2 operations, troubleshooting
- `.env.example` — tracked template for the site values only (node name, URLs, the
  Postgres coordinates, the two optional data roots, the capacity keys). It names no
  credential and points at `deploy/secret-init.sh` for all of them.
- `.agents/skills/check-updates/SKILL.md` — chart and image freshness audit, and the single
  copy of the skill.
