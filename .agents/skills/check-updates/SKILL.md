---
name: check-updates
description: Check for outdated Helm chart dependencies and container images in the deploy/postgresql and deploy/open-webui charts, then upgrade them to the latest available GA versions. Use when asked to check if deployments are running the latest versions, update outdated container images or Helm charts, or audit version freshness across all deployments.
---

# check-updates

Check for outdated Helm chart dependencies and container images, then upgrade to the latest available **GA** versions.

## Trigger

Invoke this skill when the user asks to:
- Check if deployments are running the latest versions
- Update outdated container images or Helm charts
- Audit version freshness across all deployments

## Version policy: GA only

Every pin must be the newest **generally available** release. Reject anything that is not GA.

| Pattern | Verdict |
|---|---|
| `v0.12.3`, `18.6-alpine`, `8.10.2-alpine3.23` | ✅ GA — apply |
| `17.0.1-dev.541.1` (open-webui helm chart dev builds) | ❌ skip |
| `19rc1`, `19beta4`, `*-alpha*` (Postgres 19 has no GA yet) | ❌ skip |
| `redis:*-unstable*`, `*-rc*` | ❌ skip |

Rules:

- **Never promote a prerelease**, even when it is the only thing newer than the current pin. Report that it exists and move on.
- A newer **major** (17 → 18, 18 → 19) is not a routine bump. It needs dump/restore and downtime. Report it and ask before applying. Postgres 19 stays out until a plain `19.x` tag exists on Docker Hub.
- The Open WebUI **app image** and its **Helm chart** release independently. The newest GA chart can lag the newest GA app image (chart 17.0.0 ships `appVersion: 0.12.0` while `v0.12.3` is released). That is expected: keep the chart at the newest GA and pin the app image explicitly in `values.yaml`. Do not pull a `-dev` chart just to match the app version.
- **That lag belongs to the upstream chart, and only to the upstream chart.** The rule above
  exempts the `appVersion` of the **packaged** `open-webui` chart, which you never edit. It
  does not exempt the three charts you do own: `deploy/postgresql/Chart.yaml`,
  `deploy/open-webui/Chart.yaml` and `deploy/open-webui/charts/searxng/Chart.yaml`. There,
  `appVersion` is a claim you maintain, and a stale one is wrong rather than merely lagging.
  Both rules live in this file one line apart — do not read the upstream exemption across.
- **Do not hardcode a version** — always query the registry at run time.

## What to check

| Component | Source of truth for "latest" | Query |
|---|---|---|
| `postgres` image | Docker Hub | `curl -s "https://hub.docker.com/v2/repositories/library/postgres/tags?page_size=100&ordering=last_updated"` |
| Open WebUI image | GitHub releases | `curl -s https://api.github.com/repos/open-webui/open-webui/releases?per_page=5` |
| Open WebUI helm chart | **the helm repo index, not GitHub** | `helm repo update open-webui && helm search repo open-webui/open-webui --versions` |
| SearXNG image | Docker Hub | `curl -s "https://hub.docker.com/v2/repositories/searxng/searxng/tags?page_size=15&ordering=last_updated"` |
| Redis (websocket broker) | Docker Hub | `curl -s "https://hub.docker.com/v2/repositories/library/redis/tags?page_size=100&ordering=last_updated"` |
| `alpine` (uploads backup job) | Docker Hub | `curl -s "https://hub.docker.com/v2/repositories/library/alpine/tags?page_size=20&ordering=last_updated"` |

Do not filter a registry query by major (`name=8`). A filter that presumes the major
cannot surface `9.x`, and the audit then reports "current" about a pin that was never
compared against a newer major. Read the whole list and take the highest patch of the
highest major.

Read the current value from the file first, then compare.

Where the current pin lives:

| Value | File |
|---|---|
| `image.tag` (postgres) | `deploy/postgresql/values.yaml` |
| `appVersion` (postgres) | `deploy/postgresql/Chart.yaml` |
| `open-webui.image.tag` | `deploy/open-webui/values.yaml` |
| `open-webui.websocket.redis.image.tag` | `deploy/open-webui/values.yaml` |
| `searxng.image.tag` | `deploy/open-webui/values.yaml` (the subchart's own `values.yaml` says `latest`; the parent wins) |
| `uploadsBackup.image.tag` | `deploy/open-webui/values.yaml` (the `alpine` image the uploads CronJob tars with) |
| `appVersion` | `deploy/open-webui/Chart.yaml` and `deploy/open-webui/charts/searxng/Chart.yaml` |
| dependency `version` | `deploy/open-webui/Chart.yaml` |

**SearXNG tag format is `YYYY.M.D-<git sha>`.** There is no plain date tag. Pick the newest sha build of the newest date, and sanity-check that it is the build `latest` currently points at. Several builds can share one date; taking an older sha of the right date is a silent miss.

## How to check

1. **Query registries in parallel.** The six queries are independent — run them in one batch of tool calls rather than sequentially.

   `helm search repo --versions` lists GA only, so it cannot show you what the GA policy is rejecting. Run it a second time with `--devel` and report the newest prerelease as considered-and-skipped; that is also how you tell "17.0.0 is the newest chart" from "17.0.1-dev.576.1 is waiting to be released".

2. **Collect upgrade details and benefits.** For every component that has a newer GA version available, fetch its release notes or commit summary between the current pin and the target GA version (for example, GitHub releases for Open WebUI / Redis / PostgreSQL, Helm chart release notes, and GitHub `compare/<old-sha>...<new-sha>` for SearXNG). Note any breaking changes or database migrations (`⚠️ Database Migrations`).

3. **Present the upgrade report and request per-component approval.** Before editing any files or running any backup or deploy commands, present:
   - The version summary table:

     | Component | Current | Latest GA | Status |
     |-----------|---------|-----------|--------|
     | ... | ... | ... | ✅ / ⚠️ |

   - Any prereleases considered and skipped.
   - For each outdated component: the **major benefits** of the upgrade and any **breaking changes / migration requirements**.

   **Stop and ask the user to review and explicitly approve which components to upgrade.** Do not modify `values.yaml`, `Chart.yaml`, or deploy anything until the user confirms. Proceed only with the components the user approves.

## Preflight, before any deploy

1. `pwd` — `./deploy/deploy.sh` is a relative path, so run it from the repo root; the script itself resolves `.env` and the component scripts from its own location, so an absolute path works from anywhere. A raw `helm` command must run from inside the chart directory you are deploying.
2. `helm list -n default` and `kubectl get pods -n default` — record the **baseline**: release revision, and each pod's actual running image.
3. **Confirm the target tag exists** in its registry. Deploying a tag that does not exist only surfaces later as `ImagePullBackOff`, after a rollout has already disturbed a live service:

   ```bash
   # Docker Hub
   curl -s -o /dev/null -w "%{http_code}\n" \
     "https://hub.docker.com/v2/repositories/searxng/searxng/tags/<tag>"

   # ghcr.io (needs a pull token)
   TOK=$(curl -s "https://ghcr.io/token?scope=repository:open-webui/open-webui:pull&service=ghcr.io" \
         | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")
   curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $TOK" \
     -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json" \
     "https://ghcr.io/v2/open-webui/open-webui/manifests/<tag>"
   ```

   Both must return `200`.
4. `./deploy/deploy.sh --check` — confirms the gitignored `.env` still matches both live releases, including the Brave key and `DATABASE_URL`.
5. Read the target releases' notes for **breaking changes and database migrations**. Open WebUI flags these in the release body; a `⚠️ Database Migrations` line changes what you must do next.

## Pre-upgrade database backup

Required whenever the migration path includes schema changes. Do it properly; the obvious way is a trap.

`$LIVE_DATA_PATH/postgresql-backups` (the first-copy archive dir; `set -a; . ./.env; set +a` to load it) is owned by `uid 70` (only the CronJob writes there) and there is no passwordless sudo, so a redirect there fails. Worse, when the redirect fails the shell still spawns `kubectl exec`, so **`pg_dump` starts inside the pod and is left orphaned**. It blocks forever on a dead stdout pipe in `ClientWrite` while holding an ACCESS SHARE lock, and the alembic migration then hangs on `ALTER TABLE`. The pod still reports `1/1 Running`, so the only visible symptom is `/health` returning `000`. Write the dump under `/tmp` as below and let the CronJob own the real backup dirs.

Do this instead:

```bash
mkdir -p /tmp/openwebui-upgrade && cd /tmp/openwebui-upgrade
OUT=/tmp/openwebui-upgrade/openwebui_pre-upgrade-$(date +%Y%m%d-%H%M%S).sql.gz
kubectl exec -n default deploy/postgres -- \
  pg_dump -U openwebui -d openwebui --no-owner --no-privileges | gzip > "$OUT"
echo "pg_dump exit=${PIPESTATUS[0]}"     # never trust an unverified pipeline
gzip -t "$OUT" && echo GZIP_OK
gzip -dc "$OUT" | grep -c '^CREATE TABLE'          # must be non-zero and plausible
```

Then confirm nothing was orphaned, and clean up any that was:

```bash
kubectl exec -n default deploy/postgres -- psql -U openwebui -d openwebui -c \
  "select pid, state, wait_event, left(query,50) from pg_stat_activity where application_name='pg_dump';"
# if a row is stuck in ClientWrite with no live client:
kubectl exec -n default deploy/postgres -- psql -U openwebui -d openwebui -c \
  "select pg_terminate_backend(<pid>);"
```

Record the pre-upgrade schema version and row counts so you can prove the migration worked:

```bash
kubectl exec -n default deploy/postgres -- psql -U openwebui -d openwebui -tAc \
  "select version_num from alembic_version;"
kubectl exec -n default deploy/postgres -- psql -U openwebui -d openwebui -tAc "select count(*) from chat;"
```

## How to upgrade

1. **Image tag changes** — edit the tag in the appropriate `values.yaml`. When bumping `open-webui.image.tag`, also update `open-webui.extraInitContainers[0].image` (`db-migrate`) in `deploy/open-webui/values.yaml` to the same tag so database migrations run with the new version.
2. **Helm chart version change** — edit the dependency `version` in `Chart.yaml` (exact `X.Y.Z` only; there is no `Chart.lock` to re-resolve — `deploy.sh`'s `helm dependency build` pulls the pinned version).
3. **appVersion** — update `appVersion` in the root `Chart.yaml` and in `charts/searxng/Chart.yaml` to match the pin you just edited, then run the pin-vs-`appVersion` gate in [Verifying a rollout](#verifying-a-rollout) and get `OK` on all three lines. Bumping a tag while leaving its `appVersion` behind is the specific miss this step exists to catch, and no other check in the repo reports it — the gate is the only thing that fails.
4. **Deploy with the master script** — `./deploy/deploy.sh`, run from the repo root. It
   runs PostgreSQL first (the app authenticates against it at startup), then Open WebUI,
   stops at the first component that fails, and ends with a status block for the stack.

   ```bash
   ./deploy/deploy.sh                 # both components, in dependency order
   ./deploy/deploy.sh postgresql      # only the component you bumped
   ```

   The per-component scripts are the primitives; run `deploy/postgresql/deploy.sh` or
   `deploy/open-webui/deploy.sh` directly only when you want one chart's output on its own.
   Both source the gitignored `.env` at the repo root, validate every required site
   variable, reject `CHANGE-ME` placeholders, and render their values through a `0600`
   temp file deleted on exit. Credentials are not in `.env` at all: they live in
   pre-created Kubernetes Secrets (deploy/secret-init.sh) that the scripts verify before
   helm runs — which is also why a bare `helm upgrade` is never the right command here
   (a partial values file silently resets what it omits). The open-webui script also
   runs `helm dependency build`, so the gitignored
   `charts/*.tgz` bundles are regenerated automatically.
5. **Verify the pod's actual image** — "deployed" does not mean "running the new version". K3s reuses the local containerd cache under `imagePullPolicy: IfNotPresent`:

   ```bash
   kubectl get pod <pod-name> -n default -o jsonpath='{.spec.containers[0].image}'
   ```

   If the image is unchanged, the cache is blocking the pull. Go to step 6.
6. **Image mismatch on a StatefulSet** — patch it directly. List containers first; indices vary by chart:

   ```bash
   kubectl get statefulset <name> -n default -o json | python3 -c "
   import sys,json; d=json.load(sys.stdin)
   for i,c in enumerate(d['spec']['template']['spec']['containers']): print(i, c['name'], c['image'])
   for i,c in enumerate(d['spec']['template']['spec']['initContainers']): print('init', i, c['name'], c['image'])
   "
   kubectl patch statefulset <name> -n default --type=json \
     -p '[{"op": "replace", "path": "/spec/template/spec/containers/0/image", "value": "<new-image>"},
          {"op": "replace", "path": "/spec/template/spec/containers/0/imagePullPolicy", "value": "IfNotPresent"}]'
   kubectl rollout restart statefulset <name> -n default
   ```

7. **Chart controller type change** — the upstream chart picks its kind from `.Values.workload.kind`, defaulting to `StatefulSet` when `persistence.enabled` and `persistence.provider: local`. If a chart upgrade flips the kind, `helm upgrade` will not carry the image across. `helm uninstall` then `helm install` is the clean fix; the pre-existing `open-webui` PVC survives.

## Verifying a rollout

`kubectl get pods` showing `1/1 Running` proves little unless the probes are intact. The
upstream chart ships `readinessProbe`, `livenessProbe` and `startupProbe` as `{}`
(disabled); `values.yaml` sets all three, against `/health` and `/health/db`, which both
return `{"status":true}`. If the pod reports ready while `/health` returns `000`, the
probes have been removed or overridden — restore them from `values.yaml` rather than
working around it, and keep `startupProbe.failureThreshold` generous (60 × 10s) so a long
migration is never killed. Poll the endpoint either way:

```bash
until [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:30000/health)" = "200" ]; do sleep 5; done
```

Use `kubectl rollout status statefulset/ai-open-webui` as the gate, and confirm
the pod landed in the service's **ready** addresses, not `notReadyAddresses`.

Do not read the `app.kubernetes.io/version` pod label as the deployed version: it comes
from the upstream chart's `appVersion`, which lags the pinned image. Trust the container
image and `/api/config`.

**Then prove every `appVersion` still matches its pin.** This drift is invisible to every
automated check the repo has: `helm lint` passes, `helm template` passes (the image comes
from `values.yaml`, so chart metadata is inert), and `./deploy.sh --check` compares *values*
against `.env`, and `appVersion` is chart metadata rather than a value. `helm list` prints
only the **parent** chart's `appVersion`, so a stale subchart value surfaces in no command
output at all — it lives in exactly one file, and only someone comparing two files finds it.

```bash
# Compare every pinned image tag against the appVersion that must track it.
cd "$(git rev-parse --show-toplevel)"
clean=0
tagof() { awk -v k="$2" 'BEGIN{b=0} $0 ~ "^"k":" {b=1} b && $1=="tag:" {gsub(/"/,"",$2); print $2; exit}' "$1"; }
avof()  { awk '/^appVersion:/ {gsub(/"/,"",$2); print $2; exit}' "$1"; }
check() { if [ "$2" = "$3" ]; then printf "OK        %-11s %s\n" "$1" "$2"
          else printf "MISMATCH  %-11s pin=%s  appVersion=%s\n" "$1" "$2" "$3"; clean=1; fi; }

check postgres   "$(tagof deploy/postgresql/values.yaml image    | cut -d- -f1)" \
                 "$(avof deploy/postgresql/Chart.yaml)"
check open-webui "$(tagof deploy/open-webui/values.yaml 'open-webui' | sed 's/^v//')" \
                 "$(avof deploy/open-webui/Chart.yaml)"
check searxng    "$(tagof deploy/open-webui/values.yaml searxng  | cut -d- -f1)" \
                 "$(avof deploy/open-webui/charts/searxng/Chart.yaml)"
[ $clean -eq 0 ] && echo "all pins and appVersions agree"
exit $clean
```

All three lines must print `OK`. Expect the third to be the one that breaks, because a
SearXNG bump edits `values.yaml` and nothing else: an image pinned to `2026.10.24` sat
beside `appVersion: "2026.10.19"` in exactly this state while `helm lint` and
`./deploy.sh --check` both reported success. Needs only `awk`, `sed` and `cut` — no `yq`,
which is not installed here.

Then confirm all of it, not just the happy path:

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:30000/health          # 200
curl -s http://localhost:30000/api/config | python3 -c "import sys,json;print(json.load(sys.stdin).get('version'))"
kubectl exec -n default deploy/postgres -- psql -U openwebui -d openwebui -tAc \
  "select version_num from alembic_version;"          # must have ADVANCED from pre-upgrade
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:30000/                 # 200
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:30000/login            # 200
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:30000/api/models       # 401 unauthenticated = correct
```

Checks that catch real regressions:

- **Row counts** against the backup (`chat`, `"user"`) prove the migration moved data. Quote `"user"` in shell and awk patterns — pg_dump emits it quoted.
- **Env vars on the live container** (`DEFAULT_USER_ROLE`, `ENABLE_LOGIN_FORM`, `RAG_WEB_SEARCH_ENGINE`, `DATABASE_URL`, `ENABLE_REALTIME_CHAT_SAVE`) survive as written in `values.yaml`, because `ENABLE_PERSISTENT_CONFIG` lets the app's own `config` table shadow them.
- **SearXNG actually returns results**, and each default engine answers on its own:

  ```bash
  SVC=$(kubectl get svc ai-open-webui-searxng -n default -o jsonpath='{.spec.clusterIP}')
  curl -s --max-time 20 "http://$SVC:8080/search?q=kubernetes&format=json" | python3 -c \
    "import sys,json;print(len(json.load(sys.stdin).get('results',[])),'results')"
  for e in bing braveapi "google%20cse"; do
    printf "%-12s %s\n" "$e" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
      "http://$SVC:8080/search?q=test&format=json&engines=$e")"
  done
  ```

- **The Brave key landed** in the running config — `deploy.sh` checks this, re-check if you deployed by any other route.
- **Postgres** answers: `kubectl exec -it deploy/postgres -n default -- psql -U openwebui -d openwebui -c "\dt"`. Probing NodePort 30432 with `curl` returns `000` because it is raw TCP — use a `/dev/tcp` probe or `psql`.
- **Label selectors**: use `app.kubernetes.io/component=open-webui` for the app. `app.kubernetes.io/name=open-webui` also matches the Redis broker pod, and `app=open-webui` matches nothing. For SearXNG use `app.kubernetes.io/name=searxng`; for the database pods `app.kubernetes.io/name=postgresql` (the backup job's pod carries `name=postgresql-backup` so it stays out of both the logs and the Service endpoints).

## If the migration hangs

Symptom: pod is `1/1 Running`, `/health` returns `000`, logs stop at a `Running upgrade ...` line. Find the blocker:

```bash
kubectl exec -n default deploy/postgres -- psql -U openwebui -d openwebui -c \
  "select pid, state, wait_event_type, wait_event, left(query,60) q, now()-query_start dur
   from pg_stat_activity where datname='openwebui' order by query_start nulls last;"
kubectl exec -n default deploy/postgres -- psql -U openwebui -d openwebui -c \
  "select pid, granted, left(query,60) from pg_locks l join pg_stat_activity using(pid) where not granted;"
```

An `ALTER TABLE` waiting on `wait_event=relation` is blocked by a long-running reader holding ACCESS SHARE. A session in `state=active` / `wait_event=ClientWrite` is waiting on a client that no longer exists. Confirm what it is (`application_name`, `backend_start`, full `query`) and terminate it once you are sure it is stray: `select pg_terminate_backend(<pid>);`. The migration resumes within about a minute.

## Known-benign noise

Do not spend time on these; they are pre-existing and harmless:

- SearXNG logs `ahmia: can't register engine` and `torch: can't register engine`. Hidden-service engines that need Tor; they play no part in default queries.
- `WARNING:searx.botdetection.config: missing config file: /etc/searxng/limiter.toml`.
- `/api/models` returning `401` to an unauthenticated curl. Confirm the authenticated path in the access logs instead.
- Open WebUI logging a connection error per down LLM endpoint on each model-list refresh:
  `openai.api_base_urls` in the app's own `config` table is what the app actually uses
  (`ENABLE_PERSISTENT_CONFIG` is `true`, so the row overrides the chart value that
  `deploy.sh` renders from `OPENAI_API_BASE_URL`), and it can list endpoints that are no
  longer up. Read the row and compare it against `./deploy/setup.sh --check`, which probes
  each one and prints latency.
- `helm lint` reporting `icon is recommended` for both charts.
- `helm lint` on the parent chart logging `level=WARN msg="missing required values"` for
  each `secrets.*` key and for `persistence.nodeName`. That is `templates/secret.yaml` and
  `charts/searxng/templates/pv.yaml` refusing to render blanks; it disappears once
  `./deploy.sh` supplies `.env`. A credential-less `helm template` of the parent is meant
  to fail, not to warn.

## Gotchas

- **Always `cd` into the chart directory first when you run raw helm**, and verify with `pwd`. Running `helm upgrade` from a sibling directory causes cross-chart resource collisions. `./deploy/deploy.sh` has no such constraint.
- **`imagePullPolicy: IfNotPresent` blocks new image pulls** on K3s. After editing `values.yaml`, always read the running pod's image. If unchanged, patch the workload directly.
- **List containers before patching** — indices vary by chart, and the open-webui StatefulSet has an `initContainers` entry (`copy-app-data`).
- **`helm upgrade` from the repo root or the wrong directory** is the classic way to collide the postgresql and open-webui services.
- **Helm server-side-apply conflicts**: add `--force-conflicts` if a prior `kubectl patch` claimed field ownership.
- **PostgreSQL release name must be `postgres`** — the fullname helper returns `{{ .Release.Name }}` verbatim.
- **SearXNG init container rewrites `settings.yml`** from the chart heredoc on every pod start, so an image bump refreshes config with no PV reset. Engine edits made in the SearXNG UI are lost on restart; persist them in `charts/searxng/templates/deployment.yaml`.
- **The postgres pod does not mount the backups directory.** Only the CronJob mounts `<LIVE>/postgresql-backups` (at `/backups`). Restoring means streaming from the node into the pod:

  ```bash
  set -a; . ./.env; set +a    # loads LIVE_DATA_PATH
  gzip -dc "$LIVE_DATA_PATH"/postgresql-backups/openwebui_<stamp>.sql.gz | \
    kubectl exec -i deploy/postgres -n default -- psql -U openwebui -d openwebui
  ```

  Keep `exec -i`; with `-it` the pipe is on the wrong side and `psql` runs on your workstation.
- **Both databases are covered, and coverage is a list you must maintain.** `backup.databases` in `deploy/postgresql/values.yaml` names `openwebui` and `localai`, so both are dumped daily. A database that appears on the server without being added there gets no archive and no warning; `psql -c '\l'` is the only thing that reveals the gap.
