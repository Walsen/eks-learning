# Autoscaling & Observability on EKS — KEDA + LGTM + Karpenter

A hands-on learning guide, grounded in **this** cluster
(`enterprise-eks-cluster`, us-east-1). It explains how the three systems fit
together, how each is configured here, and how to wire them end to end.

> TL;DR of the mental model:
> - **Karpenter** scales **nodes** (infrastructure).
> - **KEDA** scales **pods** (workloads), event-driven, down to zero.
> - **LGTM** **observes** everything — and its metrics can be the *signal* KEDA
>   scales on.
> They are complementary layers, not alternatives.

---

## 0. The big picture

```
                      ┌────────────────────────────────────────────┐
                      │                  GRAFANA                    │
                      │     (dashboards over metrics/logs/traces)   │
                      └──────────────▲──────────────▲───────────────┘
   observe                          │              │
 ───────────────────────────────────┼──────────────┼─────────────────────────
                                     │              │
   metrics (Prometheus/Mimir) ───────┘   logs (Loki)│   traces (Tempo)
        ▲                                            ▲
        │ scrape /metrics                            │ Alloy ships logs/traces
        │                                            │
   ┌────┴───────────────┐   KEDA reads a metric  ┌───┴───────────────────────┐
   │   YOUR WORKLOAD     │◄──────────────────────│  KEDA ScaledObject         │
   │  (Deployment/Job)   │   sets replica count  │  (event-driven autoscaler) │
   └────┬───────────────┘                        └────────────────────────────┘
        │ pods become Pending when scaled up
        ▼
   ┌────────────────────┐   provisions/*removes* EC2 nodes
   │     KARPENTER       │───────────────────────────────► AWS EC2
   │  (node autoscaler)  │   based on pending pods
   └────────────────────┘
```

The control loop you are building:

1. A workload emits a metric (e.g. requests/sec, queue depth).
2. **LGTM/Prometheus** scrapes and stores it.
3. **KEDA** queries that metric and sets the workload's replica count
   (including 0 when idle).
4. New pods that don't fit become **Pending**.
5. **Karpenter** sees the Pending pods and launches right-sized EC2 nodes; when
   pods go away it consolidates nodes back down (to zero if empty).
6. You **observe** the whole dance in **Grafana**.

---

## 1. Karpenter — node autoscaling

### 1.1 What it is
Karpenter watches for **unschedulable (Pending) pods** and provisions EC2 nodes
that fit them, then removes nodes when they're no longer needed. It replaces the
older Cluster Autoscaler + fixed node groups model with fast, flexible,
just-in-time nodes.

### 1.2 Core objects
| Object | Purpose |
|---|---|
| **NodePool** | *What* Karpenter may provision: instance types, capacity type (spot/on-demand), arch, limits, disruption policy. |
| **EC2NodeClass** | *How* on AWS: AMI, subnets, security groups, IAM role/instance profile. |
| **NodeClaim** | A single node Karpenter created (you usually just observe these). |

### 1.3 How it's configured here
**Platform side (Terraform, `eks-platform/`):**
- Karpenter is installed by `eks_blueprints_addons` (`argocd.tf`,
  `enable_karpenter = true`), **chart 1.1.0**. It creates the controller IRSA
  role, node IAM role (`karpenter-node-enterprise-eks-cluster`), SQS interruption
  queue, and the Helm release.
- A **bootstrap node group** (`eks.tf`, `system_nodes`, 2× t3.medium baseline)
  runs Karpenter itself plus CoreDNS/EBS-CSI. *Karpenter cannot run on the nodes
  it provisions — it needs a floor to start on.*
- Discovery tags: private subnets (`main.tf`) and the node security group
  (`eks.tf` `node_security_group_tags`) are tagged
  `karpenter.sh/discovery = enterprise-eks-cluster`.

**GitOps side (`eks-gitops-config/karpenter/`):**
- `ec2nodeclass.yaml` (`apiVersion: karpenter.k8s.aws/v1`): AL2023 AMI, the node
  IAM role, subnet/SG selectors using the discovery tag.
- `nodepool.yaml` (`apiVersion: karpenter.sh/v1`): spot only, amd64/linux,
  `limits.cpu: 100`, and the disruption policy below.

### 1.4 Scale-to-zero & consolidation
```yaml
disruption:
  consolidationPolicy: WhenEmptyOrUnderutilized
  consolidateAfter: 30s
```
- Karpenter has **no minimum** node count of its own. Nodes exist only while pods
  need them. When the last pod leaves a node, after `consolidateAfter` Karpenter
  terminates it — that's how the workload fleet reaches **zero**.
- The **bootstrap floor is separate** (managed node group, min 1) — it stays up
  so the controllers keep running. Use `just floor-up`/`floor-down` to toggle it
  2↔1.

### 1.5 Verify
```bash
kubectl get nodepool,ec2nodeclass          # READY=True
kubectl get nodeclaims                      # nodes Karpenter created
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter -f
```

---

## 2. LGTM — observability

LGTM = **L**oki (logs), **G**rafana (dashboards), **T**empo (traces),
**M**imir (long-term metrics). It gives you the signals to *see* what the cluster
is doing — and the metrics layer doubles as KEDA's scaling input.

### 2.1 Current state in this cluster
You currently run **kube-prometheus-stack** (Prometheus + Grafana + Alertmanager
+ node-exporter + kube-state-metrics) in namespace `monitoring`. That is the
**metrics + dashboards** part. Loki/Tempo/Mimir are planned (see
`docs/lgtm-stack.md`).

### 2.2 How metrics get collected (the key concept for KEDA)
The **Prometheus Operator** uses `ServiceMonitor` / `PodMonitor` CRs to decide
what to scrape:

```
your app exposes /metrics
   └─ ServiceMonitor (selects the app's Service)
        └─ Prometheus Operator configures Prometheus to scrape it
             └─ metric is now queryable in Prometheus  ← KEDA reads from here
```

If there is **no ServiceMonitor**, Prometheus never scrapes your app, the metric
never exists, and KEDA has nothing to scale on. This is the single most common
"my autoscaler does nothing" cause.

In-cluster Prometheus endpoint (used by KEDA later):
`http://prometheus-operated.monitoring.svc.cluster.local:9090`

### 2.3 Storage & identity (for Loki/Tempo/Mimir)
Loki/Tempo/Mimir persist to **S3**, authenticated via **EKS Pod Identity**
(no static keys). Phase 1 already created, per component:
- an S3 bucket `enterprise-eks-cluster-<component>-<account>`
- an IAM role mapped to the `<component>` service account
  (see `eks-platform/observability.tf`).

### 2.4 Collection for logs/traces (planned)
**Grafana Alloy** runs as a DaemonSet and ships **logs → Loki** and
**traces → Tempo**. One agent, three signals.

### 2.5 Verify
```bash
kubectl get pods -n monitoring
kubectl get servicemonitors -A
# Port-forward Grafana (admin password is in lgtm-values.yaml for now):
kubectl -n monitoring port-forward svc/lgtm-monitoring-stack-grafana 3000:80
```

---

## 3. KEDA — event-driven pod autoscaling

### 3.1 What it is
KEDA scales a **Deployment/StatefulSet/Job** based on **external events**
(metrics, queue depth, cron, etc.), including **scale-to-zero**. Under the hood it
creates and drives a Kubernetes **HPA**, and adds the `0↔1` transition that a
plain HPA can't do.

### 3.2 Core objects
| Object | Purpose |
|---|---|
| **ScaledObject** | Autoscale a long-running workload (Deployment). |
| **ScaledJob** | Spawn Jobs per event (batch/queue workers). |
| **TriggerAuthentication** | Credentials for a scaler (e.g. AWS auth for SQS). |

### 3.3 The Prometheus scaler (your chosen signal)
```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: myapp
  namespace: apps
spec:
  scaleTargetRef:
    name: myapp                 # Deployment to scale
  minReplicaCount: 0            # scale to zero when idle
  maxReplicaCount: 20
  pollingInterval: 30           # how often KEDA queries the metric (seconds)
  cooldownPeriod: 300           # wait this long after last activity before →0
  triggers:
    - type: prometheus
      metadata:
        serverAddress: http://prometheus-operated.monitoring.svc.cluster.local:9090
        query: sum(rate(http_requests_total{deployment="myapp"}[1m]))
        threshold: "100"          # desired metric value *per replica*
        activationThreshold: "1"  # wake from 0 only once metric > 1
```

How the replica count is computed (HPA `AverageValue` semantics):
```
desiredReplicas = ceil( queryResult / threshold )
# 350 rps / 100  → 4 replicas
# 0 rps          → 0 replicas (scaled to zero)
```

Two thresholds, two different jobs:
- **`threshold`** governs `1 → N` (how aggressively to add pods).
- **`activationThreshold`** governs `0 → 1` (when to wake up). KEDA handles this
  transition itself; the HPA only does `1 → N`.

### 3.4 Install KEDA (GitOps, fits your app-of-apps)
Add an Application that deploys the `kedacore/keda` Helm chart into namespace
`keda`, wired under `applications/` with a sync-wave so it lands after Karpenter.
KEDA's own footprint is small (operator + metrics-apiserver + scaler).

### 3.5 Gotchas
- **Don't double-autoscale:** KEDA *owns* the HPA for a target. Remove any manual
  HPA on the same Deployment.
- **Scale-from-zero latency:** at 0 replicas, KEDA only notices an event every
  `pollingInterval`; then Karpenter may need ~30–60s to provision a node; then
  image pull. Fine for async/batch; for latency-sensitive web traffic keep
  `minReplicaCount: 1`.
- **AWS scalers (SQS/CloudWatch) cost money** (polling API calls + the source
  metrics). The Prometheus scaler is free because Prometheus is already
  in-cluster.

---

## 4. Putting it together — a worked example

Goal: a demo web app that scales on request rate, on Karpenter nodes, observed in
Grafana, idling at zero.

### Step 1 — deploy the app with a metrics endpoint + ServiceMonitor
The app must expose `/metrics` (e.g. `http_requests_total`). Add a
`ServiceMonitor` so Prometheus scrapes it:
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: myapp
  namespace: apps
  labels:
    release: lgtm-monitoring-stack   # must match the Prometheus serviceMonitorSelector
spec:
  selector:
    matchLabels: { app: myapp }
  endpoints:
    - port: http
      path: /metrics
```
> The `release` label matters: kube-prometheus-stack's Prometheus only selects
> ServiceMonitors that match its `serviceMonitorSelector`. Check yours with
> `kubectl get prometheus -n monitoring -o yaml | grep -A3 serviceMonitorSelector`.

### Step 2 — confirm the metric is in Prometheus
```bash
kubectl -n monitoring port-forward svc/prometheus-operated 9090:9090
# open http://localhost:9090 and run:  sum(rate(http_requests_total[1m]))
```
If it returns data, KEDA can use it. If empty, fix scraping first (Step 1).

### Step 3 — add the KEDA ScaledObject (Section 3.3)
`minReplicaCount: 0`, Prometheus trigger on that query.

### Step 4 — generate load and watch all three layers react
```bash
# pod scaling (KEDA → HPA)
kubectl get hpa,scaledobject -n apps -w
# node scaling (Karpenter)
kubectl get nodeclaims -w
kubectl get nodes -w
# observe in Grafana: request rate, pod count, node count
```
Expected sequence: load ↑ → metric ↑ → KEDA raises replicas → pods Pending →
Karpenter adds a spot node → pods Running. Stop load → KEDA → 0 → Karpenter
consolidates the node away after 30s.

### Step 5 — order of operations matters
KEDA scaling and Karpenter provisioning are **independent loops** connected only
by *Pending pods*. KEDA never talks to Karpenter. Keep pod **resource requests**
realistic so Karpenter sizes nodes correctly.

---

## 5. How it all maps to this repo (GitOps)

```
eks-gitops-config/
├── root-app.yaml                 # app-of-apps; apply once to bootstrap ArgoCD
├── applications/                 # one ArgoCD Application per component
│   ├── storage.yaml              # gp3 StorageClass        (sync-wave -2)
│   ├── karpenter.yaml            # NodePool + EC2NodeClass (sync-wave -1)
│   ├── monitoring.yaml           # kube-prometheus-stack   (sync-wave 0)
│   └── keda.yaml                 # (to add) KEDA install
├── karpenter/                    # NodePool, EC2NodeClass
├── storage/                      # gp3 StorageClass
├── keda/                         # (to add) ScaledObjects
└── lgtm-values.yaml              # kube-prometheus-stack values
```
Flow: push to `main` → ArgoCD reconciles. `main` is **branch-protected**
(PRs required; admins may bypass), so changes go through a PR.

---

## 6. Lessons already learned on this cluster (real gotchas)

These actually happened here — worth internalizing:

1. **Bootstrap deadlock.** Karpenter can't run on nodes it hasn't created yet.
   You need a small managed-node-group floor first. (We re-enabled `system_nodes`.)
2. **Karpenter 1.0.0 broken hook.** The 1.0.x chart's post-install hook used a
   Bitnami image that was removed from public registries → stuck Helm release.
   Fixed by moving to **chart 1.1.0** (hook removed; nothing to migrate on a fresh
   v1 install).
3. **API version drift.** Karpenter 1.x uses `karpenter.sh/v1` /
   `karpenter.k8s.aws/v1`; older `v1beta1` manifests and the removed
   `WhenUnderutilized` policy are invalid.
4. **StorageClass params are immutable.** A pre-existing `gp3` blocked an updated
   one; you must delete+recreate to change parameters.
5. **Oversized CRDs.** kube-prometheus-stack's CRDs exceed the 256 KB
   client-side-apply annotation limit. ArgoCD 2.11.7 didn't honor
   `ServerSideApply` for them, so we used **`Replace=true`**.
6. **Operators must start *after* their CRDs.** The prometheus-operator predated
   its CRDs and didn't watch them until restarted.
7. **Spot + stateful EBS.** A reclaimed spot node can strand a `ReadWriteOnce`
   EBS volume in another AZ. Keep stateful workloads on-demand or single-AZ; use
   `WaitForFirstConsumer` (our gp3 SC does).
8. **Scale-from-zero is not instant.** Polling + node provisioning + image pull
   all add latency.

---

## 7. Quick reference — observe each layer

```bash
# --- Karpenter (nodes) ---
kubectl get nodepool,ec2nodeclass,nodeclaims
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter -f

# --- KEDA (pods) ---
kubectl get scaledobject,hpa -A
kubectl logs -n keda -l app=keda-operator -f

# --- LGTM (signals) ---
kubectl get pods -n monitoring
kubectl get servicemonitors,podmonitors -A
kubectl -n monitoring port-forward svc/lgtm-monitoring-stack-grafana 3000:80

# --- ArgoCD (desired state) ---
kubectl get applications -n argocd
```

---

## 8. Suggested learning path

1. **Observe first.** Open Grafana, explore the cluster dashboards. Understand
   what metrics exist and how ServiceMonitors feed them.
2. **Karpenter.** Deploy a Deployment with large resource requests / many
   replicas; watch `nodeclaims` appear, then scale to 0 and watch them go.
3. **KEDA.** Add a ScaledObject (cron trigger is easiest to start) and watch
   `0↔N` replica changes.
4. **Connect them.** Use the Prometheus trigger on a real app metric so
   KEDA-driven pods cause Karpenter to add nodes — the full loop in Section 4.
5. **Complete LGTM.** Add Loki + Alloy (logs), then Tempo (traces), then Mimir
   (long-term metrics). See `docs/lgtm-stack.md`.

---

### Related docs in this repo
- `docs/karpenter-bootstrap-fix.md` — the incident write-up and fixes.
- `docs/lgtm-stack.md` — LGTM architecture decisions and phased rollout.
