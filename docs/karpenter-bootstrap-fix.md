# Karpenter Bootstrap & Platform Hardening — Change Summary

**Date:** 2026-06-28
**Branches:** `fix/karpenter-bootstrap-and-providers` (this repo) and
`fix/karpenter-v1-and-wiring` (eks-gitops-config)
**Cluster:** `enterprise-eks-cluster` (us-east-1)

## TL;DR

Applying Karpenter left the cluster with **zero nodes**: every pod
(Karpenter, ArgoCD, CoreDNS, EBS CSI, monitoring) was stuck `Pending`. Root
cause was a removed bootstrap node group, compounded by a duplicate Karpenter
install, unpinned providers, a missing security-group discovery tag, and — on
the GitOps side — Karpenter manifests that were the wrong API version, an
absent `EC2NodeClass`, a missing `gp3` StorageClass, and nothing actually
syncing any of it.

These changes restore the cluster and remove the underlying inconsistencies
across both repositories.

---

## The incident

Karpenter cannot bootstrap itself: it needs an existing node to run on before
it can provision nodes for everything else. The platform had its bootstrap
managed node group **commented out**, so:

```
no nodes  ->  Karpenter Pending  ->  cannot provision nodes
          ->  ArgoCD Pending     ->  never applies the NodePool
          ->  everything Pending (deadlock)
```

Verified at the time via `kubectl get nodes` (`No resources found`) and
`kubectl get pods -A` (all `Pending`), plus `aws eks list-nodegroups` (empty)
and `aws ec2 describe-instances` (no instances).

---

## Platform repo changes (Terraform)

### 1. `eks.tf` — restore the bootstrap node group (the fix for the outage)
Re-enabled the `system_nodes` EKS managed node group (2× `t3.medium`). This is
the **bootstrap floor**: it runs the cluster-critical controllers. It does
**not** constrain Karpenter — `instance_types` here only governs this ASG;
Karpenter sizes workload nodes independently from its NodePool.

### 2. `eks.tf` — add Karpenter security-group discovery tag
```hcl
node_security_group_tags = {
  "karpenter.sh/discovery" = local.cluster_name
}
```
The private subnets were already tagged `karpenter.sh/discovery` (in
`main.tf`), but the node security group was not. The `EC2NodeClass`
`securityGroupSelectorTerms` rely on this tag; without it, Karpenter resolves
no security group and fails to launch nodes.

### 3. `eks.tf` — remove the duplicate Karpenter module
Karpenter was being installed **twice**:
- `module "karpenter"` (terraform-aws-modules/eks//modules/karpenter), and
- `eks_blueprints_addons` with `enable_karpenter = true`.

The blueprints module is self-sufficient — it creates the controller IRSA
role, node IAM role, instance profile, SQS interruption queue, EventBridge
rules **and** installs the Helm chart (verified in the module source). The
standalone module was pure duplication (orphaned IAM roles, a second unused
SQS queue). It has been removed; the Helm release is bound to the blueprints
resources.

> Note: the next `terraform apply` will destroy the orphaned duplicate
> resources (IAM roles, the extra SQS queue, EventBridge rules). Expected and
> safe — review the plan before applying.

### 4. `argocd.tf` — deterministic Karpenter node IAM role name
```hcl
karpenter_node = {
  iam_role_use_name_prefix = false
  iam_role_name            = "karpenter-node-${module.eks.cluster_name}"
}
```
By default the node role uses a random `name_prefix`. The GitOps `EC2NodeClass`
must reference the role name exactly via `spec.role`, so the name is now stable
(`karpenter-node-enterprise-eks-cluster`).

### 5. `providers.tf` — pin `helm` and `kubernetes` providers
Only `aws` was pinned. The `helm` and `kubernetes` providers were unpinned:
- **Helm v3 removed** the nested `provider "helm" { kubernetes { ... } }`
  block syntax used in `providers-k8s.tf`. A clean `terraform init` could pull
  v3 and break the config. Pinned to `~> 2.13`.
- `kubernetes` pinned to `~> 3.0` to match the already-locked `3.2.0`
  (a `~> 2.x` pin would have conflicted with the lock file).

### 6. `main.tf` — formatting only
`terraform fmt` alignment; no behavioral change.

**Verification:** `terraform init -backend=false` and `terraform validate`
both succeed.

---

## GitOps repo changes (ArgoCD / Karpenter manifests)

### 1. `karpenter/nodepool.yaml` — rewrite to `karpenter.sh/v1`
The manifest used `karpenter.sh/v1beta1` while the installed chart is **1.0.0**
(v1 APIs). It was also invalid:
- `consolidationPolicy: WhenUnderutilized` no longer exists → now
  `WhenEmptyOrUnderutilized`.
- `consolidateAfter` was incompatible with the old policy under v1beta1.
- `nodeClassRef` now uses the required v1 `group`/`kind`/`name` form.
- Added `kubernetes.io/arch` and `os` requirements.

### 2. `karpenter/ec2nodeclass.yaml` — NEW (was entirely missing)
The NodePool referenced an `EC2NodeClass` named `default` that did not exist,
so Karpenter could never provision. The new class:
- `spec.role` matches the deterministic node IAM role from Terraform,
- discovers subnets and the node security group via the `karpenter.sh/discovery`
  tag,
- uses `amiSelectorTerms: [{ alias: al2023@latest }]` (v1 form).

### 3. `storage/gp3-storageclass.yaml` — NEW
`lgtm-values.yaml` requests `storageClassName: gp3`, but EKS only ships a
`gp2` StorageClass — the monitoring PVCs would hang `Pending` forever. Added a
`gp3` class (`WaitForFirstConsumer` for AZ-correct binding, encrypted, default).

### 4. App-of-apps wiring — NEW
Previously **nothing synced the NodePool** — it was a loose file. Added:
- `root-app.yaml` — apply once; manages everything under `applications/`.
- `applications/{storage,karpenter,monitoring}.yaml` — child Applications, each
  syncing its own directory, ordered by sync-wave (`storage` → `karpenter` →
  `monitoring`).
- Removed the flat `karpenter-nodepool.yaml` and `monitoring-app.yaml`
  (superseded).

**Verification:** `kubectl apply --dry-run=client` accepts every document, and
the cluster's installed Karpenter CRDs recognize `karpenter.sh/v1` and
`karpenter.k8s.aws/v1`.

---

## How to roll out

1. **Platform:** `terraform apply` (review the plan; expect duplicate Karpenter
   resources to be destroyed). Nodes come up; Karpenter and ArgoCD schedule.
2. **GitOps:** once ArgoCD is healthy, `kubectl apply -f root-app.yaml` once.
   ArgoCD then syncs the StorageClass, NodePool, EC2NodeClass, and monitoring
   stack in order.
3. Confirm: `kubectl get nodeclaims` and `kubectl get nodes` should show
   Karpenter-provisioned workload nodes once unschedulable pods appear.

## Known follow-ups (not addressed here)

- **Spot-only NodePool + stateful EBS:** Prometheus/Grafana use RWO EBS
  volumes; a reclaimed spot node replaced in another AZ can strand a volume.
  Kept spot per the original cost intent — consider an on-demand pool for
  stateful workloads. Flagged in `karpenter/nodepool.yaml`.
- **Public API endpoint** is open to `0.0.0.0/0` (`cluster_endpoint_public_access`
  with no CIDR restriction). Acceptable for training; restrict for real use.
- **Grafana admin password** is committed in `lgtm-values.yaml`; move to a
  Secret / External Secrets even in training.
