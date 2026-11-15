# Security Policy

This repository deploys a self-hosted AI stack (Open WebUI, PostgreSQL,
SearXNG, Redis) on a single-node Kubernetes (K3s) cluster. Security issues in
the deployment layer — scripts, charts, defaults, and docs — are taken
seriously and fixed promptly.

## Supported versions

| Branch / tag | Supported |
|---|---|
| `main` | ✅ |
| Anything older | best effort — please test against `main` first |

## Reporting a vulnerability

**Please report security issues privately, not as a public issue.**

- Use GitHub's **private vulnerability reporting**: open the **Security** tab
  of this repository and click **"Report a vulnerability"**.
- Expect an acknowledgement within a week. This is a personal project, so
  complex fixes may take longer than a company SLA — but reports will not be
  ignored, and you will be told when a fix is on `main`.
- Please give a reasonable window before any public disclosure.

Good things to include: what you ran (or read), the affected file/line if you
know it, and the impact you see. A reproducing command line is better than a
description.

## Scope

**In scope:** the scripts under `deploy/`, the Helm charts and their values
(including the bundled `searxng` subchart), the backup/restore/uninstall
flows, and the documented procedures in `README.md`. Typical examples: a
credential reaching a command line or a tracked file, a path that lets one
component write where it should not, a script that validates less than its
docs claim.

**Out of scope:** vulnerabilities in the upstream components themselves
(Open WebUI, SearXNG, PostgreSQL, Redis, K3s, Helm) — report those to their
respective projects. If an upstream CVE affects the pinned defaults here,
open a *normal* issue asking for a version bump, or report it privately if
the exploit is trivial against a fresh install of this repo. Also out of
scope: your reverse proxy, your model endpoint, your OS, and anything that
requires you to have already ignored a loud warning in the docs.

## Hardening this repo already does

For context when judging severity: credentials live in Kubernetes Secrets
(K3s encrypts them at rest) and never in `.env`, `values.yaml`, or git; the
app, database, and search containers run as unprivileged users; the search
engine runs with a seccomp profile; backups are GPG-encrypted with a
round-trip-verified restore. A finding that bypasses one of these is
high-severity by definition.
