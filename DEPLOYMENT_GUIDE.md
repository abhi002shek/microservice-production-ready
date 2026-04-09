# Deployment Guide — Online Boutique (Production)
### EKS 1.32 · Karpenter 1.1 · ArgoCD · Jenkins · AWS ap-south-1

---

## What This Project Does

This deploys a 11-service e-commerce app (Google's Online Boutique) to AWS using:
- **Terraform** — creates all AWS infrastructure (VPC, EKS cluster, ECR, IAM)
- **Jenkins** — builds Docker images, scans for vulnerabilities, pushes to ECR
- **ArgoCD** — automatically deploys to Kubernetes when code changes
- **Karpenter** — automatically adds/removes servers based on load

You don't need to understand all of this. Just follow the steps in order.

---

## Before You Start — What You Need

### Accounts Required
- AWS account with admin access
- GitHub account (repo already exists: `https://github.com/abhi002shek/microservice-production-ready`)

### Install These Tools on Your Mac

Open **Terminal** (press `Cmd + Space`, type `Terminal`, press Enter) and run:

```bash
# Install Homebrew first (skip if already installed)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install all required tools in one command
brew install terraform awscli kubectl helm kustomize argocd eksctl
brew install --cask docker
```

After installing Docker, open the Docker app from your Applications folder and wait for it to say "Docker Desktop is running".

### Verify everything installed correctly
```bash
terraform version    # should show >= 1.10.0
aws --version        # should show >= 2.x
kubectl version --client
helm version
eksctl version
```

### Configure AWS Access

1. Go to AWS Console → IAM → Users → your user → Security credentials → Create access key
2. Run this and paste your keys when asked:

```bash
aws configure
# AWS Access Key ID:     paste your key here
# AWS Secret Access Key: paste your secret here
# Default region:        ap-south-1
# Default output format: json
```

3. Verify it works:
```bash
aws sts get-caller-identity
# You should see your Account ID printed — if yes, you're connected
```

---

## Step 1 — Create S3 Bucket for Terraform State

> This only needs to be done **once ever**. Skip if already done.

```bash
cd /path/to/microservice-production-ready/terraform
chmod +x bootstrap.sh
./bootstrap.sh
```

This creates a private S3 bucket (`boutique-tfstate-prod`) that stores Terraform's memory of what it has created. Without this, Terraform won't know what already exists.

---

## Step 2 — Create All AWS Infrastructure

This creates your VPC, EKS cluster (Kubernetes), ECR image repositories, and all IAM roles.

```bash
cd terraform/environments/prod

terraform init
```

You should see: `Terraform has been successfully initialized!`

```bash
terraform plan -out=tfplan
```

This shows you everything Terraform will create. Review it — it should show ~60 resources being created.

```bash
terraform apply tfplan
```

Type `yes` when asked. This takes **10–15 minutes**. Go get a coffee ☕

When done, save these outputs — you'll need them later:
```bash
terraform output
# Copy everything printed here to a notepad
```

---

## Step 3 — Connect kubectl to Your Cluster

```bash
aws eks update-kubeconfig \
  --name online-boutique-prod \
  --region ap-south-1
```

Test the connection:
```bash
kubectl get nodes
# Should show 2 nodes with status "Ready"
```

If you see 2 Ready nodes, your cluster is working. ✅

---

## Step 4 — Install AWS Load Balancer Controller

This controller watches your app and creates an AWS Load Balancer automatically.

```bash
cd k8s/
chmod +x install-controllers.sh
./install-controllers.sh
```

Wait for it to finish (~2 minutes), then verify:
```bash
kubectl get pods -n kube-system | grep aws-load-balancer
# Should show 2 pods with status "Running"
```

---

## Step 5 — Install Karpenter (Auto Node Scaler)

Karpenter automatically adds new servers when your app needs more capacity, and removes them when traffic drops (saves money).

```bash
cd k8s/karpenter/
chmod +x install-karpenter.sh
./install-karpenter.sh
```

This takes ~3 minutes. Verify:
```bash
kubectl get pods -n karpenter
# Should show karpenter pod with status "Running"
```

---

## Step 6 — Replace Your AWS Account ID in All Files

Your AWS Account ID is in the terraform output from Step 2. Replace `ACCOUNT_ID` everywhere:

```bash
# Go back to repo root first
cd /path/to/microservice-production-ready

# Replace ACCOUNT_ID with your real account ID (example: 616919332376)
find k8s/ -name "*.yaml" -exec sed -i '' "s/ACCOUNT_ID/YOUR_ACCOUNT_ID_HERE/g" {} \;
```

Example — if your account ID is `123456789012`:
```bash
find k8s/ -name "*.yaml" -exec sed -i '' "s/ACCOUNT_ID/123456789012/g" {} \;
```

Commit and push this change:
```bash
git add k8s/
git commit -m "config: set AWS account ID"
git push origin main
```

---

## Step 7 — Install ArgoCD (Auto Deployment Tool)

ArgoCD watches your GitHub repo and automatically deploys changes to Kubernetes.

```bash
cd k8s/argocd/
chmod +x install-argocd.sh
./install-argocd.sh
```

At the end it will print a password like:
```
ArgoCD admin password: xYz1234abcd
⚠️  Change this immediately after first login!
```

**Save this password.**

### Access ArgoCD Dashboard

```bash
# Run this in a separate terminal tab (keep it running)
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open your browser and go to: **https://localhost:8080**

- Username: `admin`
- Password: the one printed above

**Change your password immediately** after logging in: top-right → User Info → Update Password

---

## Step 8 — Set Up Jenkins

Jenkins is your CI/CD server that builds and tests code before deploying.

### Option A — Run Jenkins on an EC2 Instance (Recommended)

1. Launch an EC2 instance (Ubuntu 22.04, t3.medium) in your AWS account
2. SSH into it and run:

```bash
# Install Java
sudo apt update && sudo apt install -y openjdk-17-jdk

# Install Jenkins
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key | sudo tee /usr/share/keyrings/jenkins-keyring.asc > /dev/null
echo deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/ | sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null
sudo apt update && sudo apt install -y jenkins
sudo systemctl start jenkins

# Install Docker
sudo apt install -y docker.io
sudo usermod -aG docker jenkins
sudo systemctl restart jenkins

# Install Trivy (security scanner)
sudo apt install -y wget apt-transport-https gnupg
wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | sudo apt-key add -
echo deb https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -sc) main | sudo tee -a /etc/apt/sources.list.d/trivy.list
sudo apt update && sudo apt install -y trivy

# Install kubectl and kustomize
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
sudo mv kustomize /usr/local/bin/

# Install ArgoCD CLI
curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd
```

3. Open Jenkins at `http://YOUR_EC2_IP:8080`
4. Get the initial password: `sudo cat /var/lib/jenkins/secrets/initialAdminPassword`
5. Install suggested plugins when prompted

### Required Jenkins Plugins

Go to **Manage Jenkins → Plugins → Available** and install:
- `Pipeline`
- `Git`
- `Docker Pipeline`
- `AWS Credentials`
- `SonarQube Scanner`
- `CloudBees AWS Credentials`

### Required Jenkins Credentials

Go to **Manage Jenkins → Credentials → Global → Add Credential**:

| What to add | Type | ID to use | Value |
|---|---|---|---|
| AWS Account ID | Secret text | `aws-account-id` | Your 12-digit AWS account number |
| AWS Keys | AWS Credentials | `aws-credentials` | Your IAM access key + secret |
| GitHub Token | Username + Password | `github-token` | Username: `abhi002shek`, Password: your GitHub PAT |
| ArgoCD Token | Secret text | `argocd-token` | Generate below |
| ArgoCD Server | Secret text | `argocd-server-url` | `localhost:8080` (or your ArgoCD server address) |
| SonarQube Token | Secret text | `sonarqube` | From SonarQube → My Account → Security |

**Generate ArgoCD token:**
```bash
# Run this on your local machine
kubectl port-forward svc/argocd-server -n argocd 8080:443 &
argocd login localhost:8080 --username admin --password YOUR_ARGOCD_PASSWORD --insecure
argocd account generate-token --account admin
# Copy the printed token → paste as 'argocd-token' credential in Jenkins
```

### Create Jenkins Pipeline Jobs (one per service)

For each of the 11 services, create a pipeline job:

1. Click **New Item**
2. Name it `online-boutique-adservice` (replace `adservice` with each service name)
3. Select **Pipeline** → OK
4. Under Pipeline section:
   - Definition: `Pipeline script from SCM`
   - SCM: `Git`
   - Repository URL: `https://github.com/abhi002shek/microservice-production-ready.git`
   - Branch: `*/adservice` (change per service)
   - Script Path: `Jenkinsfile`
5. Save

The 11 services are: `adservice`, `cartservice`, `checkoutservice`, `currencyservice`, `emailservice`, `frontend`, `loadgenerator`, `paymentservice`, `productcatalogservice`, `recommendationservice`, `shippingservice`

---

## Step 9 — Push Jenkinsfiles to Each Service Branch

Each service branch needs its own `Jenkinsfile`. Run this from the repo root:

```bash
for svc in adservice cartservice checkoutservice currencyservice emailservice \
           frontend loadgenerator paymentservice productcatalogservice \
           recommendationservice shippingservice; do
  git checkout origin/$svc -b $svc 2>/dev/null || git checkout $svc
  cp jenkins/Jenkinsfile.$svc Jenkinsfile
  git add Jenkinsfile
  git commit -m "ci: add Jenkinsfile [skip ci]"
  git push origin $svc
  git checkout main
done
```

---

## Step 10 — Install Monitoring (Prometheus + Grafana)

First create the Grafana password secret (replace `YourStrongPassword123` with something secure):

```bash
kubectl create namespace monitoring

kubectl create secret generic grafana-admin-secret \
  --from-literal=admin-user=admin \
  --from-literal=admin-password='YourStrongPassword123' \
  -n monitoring
```

Then install the monitoring stack:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f k8s/monitoring/monitoring-values.yaml
```

Access Grafana dashboard:
```bash
kubectl port-forward svc/monitoring-grafana -n monitoring 3000:80
# Open http://localhost:3000
# Login: admin / YourStrongPassword123
```

---

## Step 11 — Verify Everything is Working

```bash
# Check all pods are running (takes 3-5 minutes after first deploy)
kubectl get pods -n webapps

# Get your app's public URL
kubectl get ingress -n webapps
# Copy the ADDRESS column — open it in your browser
# Example: http://k8s-webapps-abc123.ap-south-1.elb.amazonaws.com
```

Expected output — all pods should show `Running`:
```
NAME                                    READY   STATUS
adservice-xxx                           1/1     Running
cartservice-xxx                         1/1     Running
checkoutservice-xxx                     1/1     Running
currencyservice-xxx                     1/1     Running
emailservice-xxx                        1/1     Running
frontend-xxx                            1/1     Running
loadgenerator-xxx                       1/1     Running
paymentservice-xxx                      1/1     Running
productcatalogservice-xxx               1/1     Running
recommendationservice-xxx               1/1     Running
redis-cart-xxx                          1/1     Running
shippingservice-xxx                     1/1     Running
```

---

## How Deployments Work After Setup

Once everything above is done, deploying a new version of any service is automatic:

```
You push code to the adservice branch
        ↓
Jenkins automatically:
  1. Scans code for security issues (Trivy)
  2. Checks code quality (SonarQube)
  3. Builds Docker image
  4. Scans image for vulnerabilities
  5. Pushes image to ECR
  6. Updates the deployment config in GitHub
        ↓
ArgoCD automatically:
  7. Detects the config change in GitHub
  8. Rolls out the new version to Kubernetes
  9. Zero downtime — old pods stay up until new ones are healthy
```

You don't need to do anything manually after the initial setup.

---

## Adding HTTPS (When You Buy a Domain)

```bash
# 1. Request a free SSL certificate from AWS
aws acm request-certificate \
  --domain-name yourdomain.com \
  --validation-method DNS \
  --region ap-south-1

# 2. AWS will show you a CNAME record to add to your domain's DNS
#    Add it in your domain registrar's DNS settings

# 3. Get the certificate ARN (after DNS validation completes ~5 min)
aws acm list-certificates --region ap-south-1

# 4. Edit k8s/base/ingress.yaml — add these 3 lines under annotations:
#    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
#    alb.ingress.kubernetes.io/ssl-redirect: "443"
#    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:ap-south-1:YOUR_ACCOUNT:certificate/CERT-ID

# 5. Commit and push — ArgoCD deploys it automatically
git add k8s/base/ingress.yaml
git commit -m "feat: enable HTTPS"
git push origin main
```

---

## Rollback a Bad Deployment

If something breaks after a deployment:

```bash
# Option 1 — Roll back via ArgoCD (easiest)
argocd app history online-boutique   # see all deployments
argocd app rollback online-boutique 3  # roll back to revision 3

# Option 2 — Emergency rollback of one service
kubectl rollout undo deployment/frontend -n webapps

# Option 3 — Revert the git commit (ArgoCD auto-deploys the revert)
git revert HEAD
git push origin main
```

---

## Troubleshooting

**Pods stuck in `Pending` state:**
```bash
kubectl describe pod POD_NAME -n webapps
# Look for "Events" section at the bottom — it tells you why
```

**Karpenter not launching new nodes:**
```bash
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter | tail -30
```

**App URL not working / ALB not created:**
```bash
kubectl logs -n kube-system deployment/aws-load-balancer-controller | tail -20
```

**ArgoCD shows app as OutOfSync:**
```bash
argocd app sync online-boutique
```

**Jenkins pipeline failing on git push:**
```bash
# This is usually a concurrent push conflict — re-run the pipeline
# The Jenkinsfiles already have git pull --rebase to handle this
```

---

## Monthly Cost Estimate (ap-south-1)

| Resource | ~Cost/Month |
|---|---|
| EKS control plane | $73 |
| 2x t3.medium system nodes (always on) | $60 |
| Karpenter workload nodes (scales with traffic) | $50–150 |
| 3x NAT Gateways | $100 |
| Application Load Balancer | $20 |
| ECR (11 repos) | $5 |
| CloudWatch logs | $10 |
| **Total estimate** | **~$320–420/month** |

**To reduce cost during testing:**
- Change NAT Gateways from 3 to 1 in `terraform/modules/vpc/main.tf` (single AZ, not HA)
- Karpenter already prefers Spot instances which are 60–70% cheaper than On-Demand

---

## Infrastructure Versions

| Component | Version |
|---|---|
| EKS (Kubernetes) | 1.32 |
| Karpenter | 1.1.0 |
| vpc-cni addon | v1.18.3-eksbuild.1 |
| coredns addon | v1.11.3-eksbuild.1 |
| kube-proxy addon | v1.32.0-eksbuild.1 |
| aws-ebs-csi-driver addon | v1.37.0-eksbuild.1 |
| Terraform | >= 1.10.0 |

---

## File Structure Reference

```
microservice-production-ready/
├── DEPLOYMENT_GUIDE.md          ← you are here
├── terraform/
│   ├── bootstrap.sh             ← run once: creates S3 bucket for state
│   ├── environments/prod/
│   │   ├── main.tf              ← calls vpc + eks + ecr modules
│   │   ├── variables.tf         ← region, cluster version, service list
│   │   └── outputs.tf           ← prints cluster name, ECR URLs etc
│   └── modules/
│       ├── vpc/main.tf          ← VPC, subnets, NAT gateways
│       ├── eks/main.tf          ← EKS cluster, IAM, Karpenter infra
│       └── ecr/main.tf          ← 11 ECR image repositories
├── k8s/
│   ├── base/                    ← Kubernetes manifests for all services
│   ├── overlays/prod/           ← production image tags (updated by Jenkins)
│   ├── security/                ← network policies (who can talk to who)
│   ├── argocd/                  ← ArgoCD install + config
│   ├── karpenter/               ← Karpenter install + node config
│   ├── monitoring/              ← Prometheus + Grafana config
│   └── install-controllers.sh  ← installs AWS Load Balancer Controller
└── jenkins/
    └── Jenkinsfile.*            ← one pipeline file per service
```
