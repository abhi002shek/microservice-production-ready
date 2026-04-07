# Production Deployment Guide — Online Boutique Microservices
## DevSecOps on AWS EKS with Karpenter + ArgoCD + Jenkins

---

## Architecture Overview

```
Developer Push (per-service branch)
     │
     ▼
   GitHub
     │
     ▼
Jenkins CI Pipeline (one job per service branch)
  ├── Trivy FS Scan          (blocks on HIGH/CRITICAL in source)
  ├── SonarQube + Quality Gate (blocks on code quality failures)
  ├── Docker Build
  ├── Trivy Image Scan       (blocks on HIGH/CRITICAL in image)
  ├── Push to ECR            (immutable tag: <build>-<git-sha>)
  └── Update k8s/overlays/prod/kustomization.yaml → push to main
           │
           ▼ (ArgoCD watches main branch)
     ArgoCD GitOps Sync
           │
           ▼
     EKS Cluster — online-boutique-prod (ap-south-1)
           │
     ┌─────┴──────────────────────────────────────────┐
     │  2x system nodes (t3.medium, fixed)             │
     │  └─ karpenter, coredns, kube-system pods        │
     │                                                  │
     │  Karpenter-managed nodes (auto, t3/m5/m6i/c5)  │
     │  └─ namespace: webapps                          │
     │     ├── frontend (3 replicas)                   │
     │     ├── 10 backend microservices (2 replicas)   │
     │     ├── redis-cart                              │
     │     ├── NetworkPolicies (default deny)          │
     │     ├── HPA + PodDisruptionBudgets              │
     │     └── SecurityContext hardening on all pods   │
     └──────────────────────────────────────────────────┘
           │
     AWS ALB (internet-facing, HTTP)
           │
     http://<ALB-DNS>   ← your app URL (no domain needed yet)
```

**AWS Account:**
**Region:** ap-south-1  
**GitHub Repo:** https://github.com/abhi002shek/microservice-production-ready

---

## Prerequisites

Install on your local machine:

```bash
# macOS
brew install terraform awscli kubectl helm kustomize argocd eksctl
brew install --cask docker
```

Minimum versions:
```
terraform >= 1.6.0
aws CLI  >= 2.x
kubectl  >= 1.29
helm     >= 3.x
eksctl   >= 0.170
```

Configure AWS credentials:
```bash
aws configure
# AWS Access Key ID:     <your-key>
# AWS Secret Access Key: <your-secret>
# Default region:        ap-south-1
# Default output format: json

# Verify
aws sts get-caller-identity
# Should show Account: xxxxxx
```

---

## Step 1 — Bootstrap Terraform Remote State

Run this **once only** before any `terraform` commands. It creates the S3 bucket
and DynamoDB table used to store and lock Terraform state remotely.

```bash
cd terraform/
chmod +x bootstrap.sh
./bootstrap.sh
```

What it creates:
- S3 bucket `boutique-tfstate-prod` — versioned, KMS-encrypted, public access blocked
- DynamoDB table `boutique-tfstate-lock` — prevents concurrent `terraform apply` runs

---

## Step 2 — Provision AWS Infrastructure with Terraform

```bash
cd terraform/environments/prod/

terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

**VPC module** provisions:
- VPC `10.0.0.0/16` across 3 AZs (ap-south-1a/b/c)
- 3 private subnets `10.0.1-3.0/24` — all EKS nodes live here (no public IPs)
- 3 public subnets `10.0.101-103.0/24` — NAT Gateways + ALB
- 3 NAT Gateways (one per AZ for high availability)
- Subnet tags so EKS can auto-discover subnets for ALB and internal load balancers

**EKS module** provisions:
- Managed EKS cluster v1.29, private + public endpoint
- KMS key — encrypts all Kubernetes Secrets at rest
- CloudWatch control plane logs — api, audit, authenticator, controllerManager, scheduler
- OIDC provider — enables IRSA (IAM Roles for Service Accounts, no static keys in pods)
- **2-node system node group** (t3.medium, fixed size, tainted `CriticalAddonsOnly`)
  - These 2 nodes run: Karpenter controller, CoreDNS, kube-proxy, kube-system pods
  - Karpenter cannot launch itself, so these nodes are the bootstrap floor
- **Karpenter IAM role** (IRSA) — controller calls EC2 APIs to launch/terminate nodes
- **Karpenter node IAM role + instance profile** — EC2 instances launched by Karpenter
- **SQS queue** — receives EC2 spot interruption events so Karpenter can drain nodes gracefully
- **EventBridge rules** — forwards spot interruption, rebalance, state-change, health events to SQS
- EKS add-ons: vpc-cni, coredns, kube-proxy, aws-ebs-csi-driver

**ECR module** provisions:
- 11 private ECR repositories (one per microservice)
- Immutable image tags — cannot overwrite an existing tag
- Scan on push — AWS Inspector scans every image automatically
- Lifecycle policy — keeps last 10 images, deletes older ones

After apply, save these outputs:
```bash
terraform output cluster_name                      # online-boutique-prod
terraform output karpenter_controller_role_arn     # used by Karpenter Helm install
terraform output karpenter_node_instance_profile_name
terraform output karpenter_interruption_queue_name
terraform output ecr_repository_urls               # ECR URLs for all 11 services
```

---

## Step 3 — Configure kubectl

```bash
aws eks update-kubeconfig \
  --name online-boutique-prod \
  --region ap-south-1

# Verify — should show 2 system nodes in Ready state
kubectl get nodes
```

---

## Step 4 — Install AWS Load Balancer Controller

The LBC watches Ingress resources and creates/manages AWS ALBs automatically.

```bash
cd k8s/
chmod +x install-controllers.sh
./install-controllers.sh
```

What it does:
- Creates IAM policy `AWSLoadBalancerControllerIAMPolicy` in your account
- Creates a Kubernetes ServiceAccount with IRSA annotation (no static AWS keys in cluster)
- Installs LBC via Helm in `kube-system`

Verify:
```bash
kubectl get pods -n kube-system | grep aws-load-balancer
# Should show 2 pods Running
```

---

## Step 5 — Install Karpenter

Karpenter is the automatic node provisioner. It replaces Cluster Autoscaler.
Instead of scaling a fixed ASG, Karpenter watches for `Pending` pods and calls
EC2 `RunInstances` directly — nodes are ready in ~60 seconds.

```bash
cd k8s/karpenter/
chmod +x install-karpenter.sh
./install-karpenter.sh
```

What it does:
1. Registers the Karpenter node IAM role in `aws-auth` ConfigMap so launched nodes can join the cluster
2. Installs Karpenter v0.37.0 via Helm — runs on the system nodes (tolerates `CriticalAddonsOnly` taint)
3. Applies `EC2NodeClass` — AL2023 AMI, 50GB encrypted gp3, IMDSv2 enforced, auto-discovers subnets/SGs by cluster tag
4. Applies `NodePool` — allows t3/t3a/m5/m6i/c5/c6i families, On-Demand + Spot, min 2 vCPUs, hard cap 80 vCPU / 160Gi

**How Karpenter scales:**
- Pods go `Pending` → Karpenter picks cheapest fitting instance → node ready in ~60s
- Node empty for 30s → Karpenter terminates it (cost saving)
- Spot interruption → SQS receives event → Karpenter cordons + drains node before AWS reclaims it

Monitor:
```bash
kubectl get nodeclaims                                              # active nodes
kubectl get nodepools                                               # pool limits/usage
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter -f  # live logs
```

---

## Step 6 — Replace Placeholder Values in Manifests

```bash
# Replace ACCOUNT_ID with your real account ID in all k8s YAML files
find k8s/ -name "*.yaml" -exec sed -i '' "s/ACCOUNT_ID/616919332376/g" {} \;
```

**In `k8s/argocd/project.yaml` and `k8s/argocd/application.yaml`:**
Replace `YOUR_ORG` with `abhi002shek`:
```bash
find k8s/argocd/ -name "*.yaml" -exec sed -i '' "s/YOUR_ORG/abhi002shek/g" {} \;
```

**In all `jenkins/Jenkinsfile.*` files:**
```bash
find jenkins/ -name "Jenkinsfile.*" -exec sed -i '' "s/YOUR_ORG/abhi002shek/g" {} \;
```

**`k8s/base/ingress.yaml`** — no changes needed. HTTP-only, no domain required.
When you buy a domain later, follow the comments at the top of that file.

**`k8s/base/serviceaccount.yaml`** — update the IRSA role ARN:
```bash
# Get the role ARN
ROLE_ARN=$(aws iam get-role --role-name online-boutique-prod-sa-role \
  --query Role.Arn --output text 2>/dev/null || echo "create-this-role-first")

# Or use the karpenter node role for now (update after creating a dedicated SA role)
```

---

## Step 7 — Install ArgoCD

```bash
cd k8s/argocd/
chmod +x install-argocd.sh
./install-argocd.sh
```

What it does:
- Installs ArgoCD stable in `argocd` namespace
- Applies `AppProject` (boutique-prod) — whitelists only the resources ArgoCD is allowed to manage
- Applies `Application` — tells ArgoCD to watch `k8s/overlays/prod/` on the `main` branch
- Prints the initial admin password

Access ArgoCD UI:
```bash
# Get the LoadBalancer URL
kubectl get svc argocd-server -n argocd

# Login
argocd login <ARGOCD_LB_URL> --username admin --password <INITIAL_PASSWORD>

# Change password immediately
argocd account update-password
```

Key ArgoCD settings in `application.yaml`:
- `automated.prune: true` — resources deleted from Git are removed from cluster
- `automated.selfHeal: true` — manual cluster changes are reverted automatically
- `retry.limit: 5` — failed syncs retry with exponential backoff (5s → 3m max)

---

## Step 8 — Set Up Jenkins

### Required Plugins
Install from Jenkins → Manage Plugins:
- Pipeline, Git, Docker Pipeline
- AWS Steps (`aws-credentials` plugin)
- SonarQube Scanner
- Kubernetes CLI

### Required Credentials
Jenkins → Manage Jenkins → Credentials → Global → Add:

| Credential ID       | Type               | Value                                         |
|---------------------|--------------------|-----------------------------------------------|
| `aws-account-id`    | Secret text        | `616919332376`                                |
| `aws-credentials`   | AWS Credentials    | IAM access key + secret (ECR push permission) |
| `github-token`      | Username+Password  | `abhi002shek` + GitHub Personal Access Token  |
| `argocd-token`      | Secret text        | ArgoCD API token (generate below)             |
| `argocd-server-url` | Secret text        | ArgoCD server hostname (no `https://`)        |
| `sonarqube`         | Secret text        | SonarQube token                               |

Generate ArgoCD token:
```bash
argocd account generate-token --account jenkins
# Paste output as 'argocd-token' credential
```

### Create Pipeline Jobs (one per service)

For each service, create a Jenkins Pipeline job:
1. New Item → Pipeline → name: `online-boutique-<service>`
2. Pipeline → Definition: **Pipeline script from SCM**
3. SCM: Git, URL: `https://github.com/abhi002shek/microservice-production-ready.git`
4. Branch: `origin/<service>` (e.g. `origin/adservice`)
5. Script Path: `Jenkinsfile`

Then push the corresponding `jenkins/Jenkinsfile.<service>` content as `Jenkinsfile`
into each service branch (see Step 10 — Per-Branch Jenkinsfile Push).

### Jenkins IAM Policy
The IAM user used by Jenkins needs this policy:
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage"
    ],
    "Resource": "*"
  }]
}
```

---

## Step 9 — Install Monitoring Stack

```bash
kubectl create namespace monitoring

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f k8s/monitoring/monitoring-values.yaml
```

Installs:
- Prometheus — 15-day retention, 50GB gp3 persistent volume
- Grafana — dashboards, internal ALB access
- Alertmanager — alert routing
- Node Exporter + kube-state-metrics
- Pre-built alert rules for pods, nodes, cluster health

Access Grafana:
```bash
kubectl get svc -n monitoring | grep grafana
# Login: admin / CHANGE_ME_USE_SECRET  (update in monitoring-values.yaml before install)
```

---

## Step 10 — Per-Branch Jenkinsfile Push

Each service branch needs its own `Jenkinsfile`. The files are in `jenkins/` on `main`.
Push each one to its corresponding branch:

```bash
# Example for adservice — repeat for all 11 services
git checkout adservice
cp jenkins/Jenkinsfile.adservice Jenkinsfile
git add Jenkinsfile
git commit -m "ci: add production Jenkinsfile"
git push origin adservice
git checkout main
```

Or run this loop:
```bash
for svc in adservice cartservice checkoutservice currencyservice emailservice \
           frontend loadgenerator paymentservice productcatalogservice \
           recommendationservice shippingservice; do
  git checkout origin/$svc -b $svc 2>/dev/null || git checkout $svc
  cp jenkins/Jenkinsfile.$svc Jenkinsfile
  git add Jenkinsfile
  git commit -m "ci: add production Jenkinsfile [skip ci]"
  git push origin $svc
  git checkout main
done
```

---

## Step 11 — Verify Full Deployment

```bash
# All pods running
kubectl get pods -n webapps

# Get your app URL — copy the ADDRESS column
kubectl get ingress -n webapps
# Open: http://<ALB-DNS-ADDRESS> in browser

# Karpenter nodes
kubectl get nodes
kubectl get nodeclaims

# HPA
kubectl get hpa -n webapps

# ArgoCD sync status
argocd app get online-boutique
```

Expected pods in `webapps`:
```
adservice-xxx               2/2  Running
cartservice-xxx             2/2  Running
checkoutservice-xxx         2/2  Running  (3/3 in prod overlay)
currencyservice-xxx         2/2  Running
emailservice-xxx            2/2  Running
frontend-xxx                3/3  Running
loadgenerator-xxx           1/1  Running
paymentservice-xxx          2/2  Running
productcatalogservice-xxx   2/2  Running
recommendationservice-xxx   2/2  Running
redis-cart-xxx              1/1  Running
shippingservice-xxx         2/2  Running
```

---

## CI/CD Flow — What Happens on Every Code Push

```
git push → adservice branch
    │
    ├─ [1] Trivy FS scan source code
    │       FAIL → pipeline stops, no image built
    │
    ├─ [2] SonarQube analysis + Quality Gate
    │       FAIL → pipeline stops
    │
    ├─ [3] docker build → image:1234-abc1234
    │
    ├─ [4] Trivy image scan
    │       FAIL → pipeline stops, image NOT pushed
    │
    ├─ [5] docker push → ECR (immutable tag)
    │
    ├─ [6] kustomize edit set image → commit to main branch
    │       k8s/overlays/prod/kustomization.yaml updated
    │
    └─ [7] ArgoCD detects diff → rolling update on EKS
            zero downtime (2 replicas, PDB ensures 1 always up)
```

---

## Adding HTTPS When You Buy a Domain

When you purchase a domain, follow these steps:

```bash
# 1. Request ACM certificate (must be in ap-south-1)
aws acm request-certificate \
  --domain-name yourdomain.com \
  --validation-method DNS \
  --region ap-south-1

# 2. Complete DNS validation in Route53 (ACM shows the CNAME to add)

# 3. Get the certificate ARN
aws acm list-certificates --region ap-south-1

# 4. Update k8s/base/ingress.yaml — replace the annotations block with:
#    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
#    alb.ingress.kubernetes.io/ssl-redirect: "443"
#    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:ap-south-1:616919332376:certificate/<CERT-ID>
#    And add under spec.rules:
#    - host: yourdomain.com

# 5. Create Route53 A record (alias) pointing to the ALB DNS
# 6. Commit and push — ArgoCD applies the change automatically
```

---

## Security Controls

| Control                  | Implementation                                           |
|--------------------------|----------------------------------------------------------|
| Image CVE scanning       | Trivy blocks pipeline on HIGH/CRITICAL                   |
| Source code scanning     | Trivy FS + SonarQube on every commit                     |
| ECR scanning             | AWS Inspector scans on every push                        |
| Immutable image tags     | ECR IMMUTABLE — no tag overwriting                       |
| No root containers       | `runAsNonRoot: true`, `runAsUser: 1000` on all pods      |
| No privilege escalation  | `allowPrivilegeEscalation: false` on all containers      |
| Dropped capabilities     | `capabilities.drop: [ALL]` on all containers             |
| Read-only root FS        | `readOnlyRootFilesystem: true` on all containers         |
| Seccomp                  | `RuntimeDefault` profile on all pods                     |
| Network segmentation     | Default deny-all + explicit per-service NetworkPolicies  |
| Secrets encryption       | KMS encrypts all Kubernetes Secrets at rest              |
| IMDSv2 enforced          | All nodes (system + Karpenter-launched) require IMDSv2   |
| Encrypted node disks     | 50GB gp3 EBS encrypted with KMS on all nodes            |
| Private nodes            | All nodes in private subnets, no public IPs              |
| No static AWS keys       | IRSA for all AWS access (LBC, Karpenter, service pods)   |
| GitOps enforcement       | ArgoCD selfHeal reverts any manual cluster changes       |
| Control plane audit logs | All 5 log types → CloudWatch                             |

---

## Rollback

```bash
# Option 1 — ArgoCD UI or CLI (recommended)
argocd app history online-boutique
argocd app rollback online-boutique <REVISION>

# Option 2 — Git revert (ArgoCD auto-syncs)
git revert <commit-that-updated-kustomization>
git push origin main

# Option 3 — Emergency direct rollback
kubectl rollout undo deployment/frontend -n webapps
```

---

## Troubleshooting

```bash
# Pod not starting
kubectl describe pod <pod> -n webapps
kubectl logs <pod> -n webapps --previous

# Karpenter not launching nodes
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter | tail -50

# ALB not created
kubectl logs -n kube-system deployment/aws-load-balancer-controller

# ArgoCD stuck
argocd app sync online-boutique --force

# Network policy blocking traffic (test by temporarily removing)
kubectl delete networkpolicy default-deny-all -n webapps
```

---

## File Structure

```
microservice-production-ready/          ← main branch
├── DEPLOYMENT_GUIDE.md                 ← this file
├── terraform/
│   ├── bootstrap.sh                    # run once: creates S3 + DynamoDB for state
│   ├── environments/prod/
│   │   ├── main.tf                     # calls vpc + eks + ecr modules
│   │   ├── variables.tf                # region, CIDRs, cluster version, service list
│   │   └── outputs.tf                  # cluster name, ECR URLs, Karpenter role ARNs
│   └── modules/
│       ├── vpc/main.tf                 # VPC, 3 AZs, private/public subnets, NAT GWs
│       ├── eks/main.tf                 # EKS cluster, KMS, OIDC, system nodes,
│       │                               # Karpenter IAM + SQS + EventBridge
│       └── ecr/main.tf                 # 11 ECR repos, immutable tags, lifecycle
├── k8s/
│   ├── base/
│   │   ├── namespace.yaml              # webapps namespace
│   │   ├── serviceaccount.yaml         # shared SA with IRSA annotation
│   │   ├── deployments.yaml            # all 12 services, hardened security contexts
│   │   ├── ingress.yaml                # ALB Ingress, HTTP (HTTPS instructions inside)
│   │   ├── hpa.yaml                    # HPA for frontend, checkout, cart, productcatalog
│   │   ├── pdb.yaml                    # PodDisruptionBudgets for 5 critical services
│   │   └── kustomization.yaml
│   ├── overlays/prod/
│   │   └── kustomization.yaml          # image tags updated here by Jenkins on each build
│   ├── security/
│   │   └── network-policies.yaml       # default deny-all + 11 per-service allow rules
│   ├── argocd/
│   │   ├── project.yaml                # AppProject — restricts what ArgoCD can deploy
│   │   ├── application.yaml            # Application — watches k8s/overlays/prod on main
│   │   └── install-argocd.sh           # installs ArgoCD + applies project + application
│   ├── karpenter/
│   │   ├── nodepool.yaml               # EC2NodeClass + NodePool (auto node provisioning)
│   │   └── install-karpenter.sh        # installs Karpenter via Helm + applies nodepool
│   ├── monitoring/
│   │   └── monitoring-values.yaml      # kube-prometheus-stack Helm values
│   └── install-controllers.sh          # installs AWS Load Balancer Controller
└── jenkins/
    ├── Jenkinsfile.shared              # annotated reference (not used directly)
    ├── Jenkinsfile.adservice           # push to adservice branch as Jenkinsfile
    ├── Jenkinsfile.cartservice
    ├── Jenkinsfile.checkoutservice
    ├── Jenkinsfile.currencyservice
    ├── Jenkinsfile.emailservice
    ├── Jenkinsfile.frontend
    ├── Jenkinsfile.loadgenerator
    ├── Jenkinsfile.paymentservice
    ├── Jenkinsfile.productcatalogservice
    ├── Jenkinsfile.recommendationservice
    └── Jenkinsfile.shippingservice
```

---

## Cost Estimate (ap-south-1, monthly)

| Resource                         | ~Cost/Month |
|----------------------------------|-------------|
| EKS control plane                | $73         |
| 2x t3.medium system nodes        | $60         |
| Karpenter nodes (variable)       | $50–150     |
| 3x NAT Gateways                  | $100        |
| ALB                              | $20         |
| ECR (11 repos)                   | $5          |
| CloudWatch logs                  | $10         |
| SQS (Karpenter interruption)     | <$1         |
| **Total estimate**               | **~$320–420/month** |

To reduce cost: use 1 NAT Gateway (single AZ), reduce system nodes to t3.small,
set Karpenter to prefer Spot instances (already configured in NodePool).
