# LGTM Observability Stack — Design & Rollout

Goal: move from metrics-only (kube-prometheus-stack) to the full **LGTM** stack —
**L**oki (logs), **G**rafana (dashboards), **T**empo (traces), **M**imir
(long-term metrics).

## Agreed architecture

- **Object storage:** S3, one bucket per component, access via **EKS Pod
  Identity** (same pattern as the EBS CSI driver), scoped per bucket.
- **Metrics:** **complement** Prometheus, don't replace it — keep
  kube-prometheus-stack scraping/alerting and `remote_write` to Mimir for
  long-term storage.
- **Collection:** **Grafana Alloy** (one DaemonSet) for logs and trace ingest.
- **Sizing:** **monolithic / single-binary** per component (not distributed) —
  appropriate for this cluster size and still S3-backed.
- **Grafana:** reuse the single Grafana from kube-prometheus-stack; add Loki /
  Tempo / Mimir datasources.

## Rollout phases

| Phase | Scope | Repo | Status |
|---|---|---|---|
| 1 | S3 buckets + Pod Identity IAM | eks-platform (TF) | **in progress** |
| 2 | Loki (logs) + Alloy collector | eks-gitops-config | pending |
| 3 | Tempo (traces) | eks-gitops-config | pending |
| 4 | Mimir + Prometheus remote_write | both | pending |

## Phase 1 details (`eks-platform/observability.tf`)

- 3 S3 buckets: `enterprise-eks-cluster-{loki,tempo,mimir}-<account_id>`
  (SSE-S3, public access blocked, ACLs disabled, abort-incomplete-MPU lifecycle,
  `force_destroy = true` for the training env).
- 3 Pod Identity roles, each granting S3 access to **only** its bucket, mapped
  to the component's Kubernetes service account.
- Naming contract (must match later Helm releases):
  `release name == namespace == service account name` = `loki` / `tempo` /
  `mimir`.
- Outputs: `lgtm_bucket_names`, `lgtm_pod_identity_role_arns` — consumed by the
  Helm values in Phases 2-4.

Object/block **retention is managed by each component's compactor**, not by S3
lifecycle expiration, to avoid deleting data the store still references.

## Cost note

Loki/Tempo/Mimir ingesters stay running, so this adds steady-state pods ->
Karpenter node(s) even at idle, plus S3 storage/requests. Expect this to be the
main driver of baseline node cost.
