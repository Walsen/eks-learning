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
- **Collection:** **Grafana Alloy**. *Implemented as a single Deployment using
  API-based log collection (`loki.source.kubernetes`)* — one instance reads all
  pods' logs. A per-node DaemonSet would duplicate streams and hit the t3.medium
  ~17-pod density cap. Production-scale: DaemonSet tailing node-local files
  (`/var/log/pods`) + VPC CNI prefix delegation.
- **Sizing:** **monolithic / single-binary** per component (not distributed) —
  appropriate for this cluster size and still S3-backed.
- **Grafana:** reuse the single Grafana from kube-prometheus-stack; add Loki /
  Tempo / Mimir datasources.

## Rollout phases

| Phase | Scope | Repo | Status |
|---|---|---|---|
| 1 | S3 buckets + Pod Identity IAM | eks-platform (TF) | **done** |
| 2 | Loki (logs) + Alloy collector | eks-gitops-config | **done** |
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

## Phase 2 details (`eks-gitops-config/applications/{loki,alloy}.yaml`)

- **Loki** 6.55.0 (Loki 3.6.7), `deploymentMode: SingleBinary`, S3-backed via the
  `loki` bucket + Pod Identity (release/ns/sa = `loki`). tsdb + v13 schema; caches,
  canary, and bundled MinIO disabled for a small footprint; 10Gi gp3 PVC for WAL.
- **Alloy** 1.10.0 as a **single Deployment** (see Collection note above), tailing
  pod logs via the K8s API → `loki-gateway`.
- **Grafana** gets a **Loki datasource** (`lgtm-values.yaml` `additionalDataSources`).
- Verified: chunks land in S3; logs queryable across all namespaces.

Gotchas hit (and fixed) in Phase 2:
- Alloy DaemonSet → Deployment (duplicate collection + t3.medium pod-density cap).
- Monitoring sync hung on the kube-prometheus-stack **admission-webhook hooks**
  under `Replace=true` → disabled the webhook (`prometheusOperator.admissionWebhooks.enabled: false`).

## Capacity: VPC CNI prefix delegation

The t3.medium ~17-pod cap caused Pending pods. `eks.tf` now enables
**prefix delegation** on the `vpc-cni` addon
(`ENABLE_PREFIX_DELEGATION=true`, `WARM_PREFIX_TARGET=1`), raising the cap to
~110 pods/node. Takes effect on **new ENIs** — recycle existing nodes after
applying. Do this before Phase 3/4 (Tempo/Mimir add more pods).

## Cost note

Loki/Tempo/Mimir ingesters stay running, so this adds steady-state pods ->
Karpenter node(s) even at idle, plus S3 storage/requests. Expect this to be the
main driver of baseline node cost.
