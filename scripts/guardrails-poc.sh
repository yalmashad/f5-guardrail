#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_CONFIG="$ROOT_DIR/config/guardrails-poc.env"
EXAMPLE_CONFIG="$ROOT_DIR/config/guardrails-poc.env.example"

CONFIG_FILE="$DEFAULT_CONFIG"
DRY_RUN=false
ASSUME_YES=false

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  scripts/guardrails-poc.sh [--config FILE] [--dry-run] up
  scripts/guardrails-poc.sh [--config FILE] [--dry-run] down [--yes]
  scripts/guardrails-poc.sh [--config FILE] [--dry-run] status

Secret inputs:
  Harbor:
    HARBOR_USERNAME and HARBOR_PASSWORD environment variables, or
    HARBOR_CREDENTIALS_FILE with username on line 1 and password on line 2.

  License:
    F5_LICENSE_STRING environment variable, or
    F5_LICENSE_FILE containing the license string.

Examples:
  cp config/guardrails-poc.env.example config/guardrails-poc.env
  scripts/guardrails-poc.sh up
  scripts/guardrails-poc.sh status
  scripts/guardrails-poc.sh down --yes
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_FILE="${2:-}"
      [[ -n "$CONFIG_FILE" ]] || die "--config requires a file path"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --yes|-y)
      ASSUME_YES=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    up|down|status)
      ACTION="$1"
      shift
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

ACTION="${ACTION:-}"
[[ -n "$ACTION" ]] || { usage; exit 1; }

load_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    if [[ "$CONFIG_FILE" == "$DEFAULT_CONFIG" && -f "$EXAMPLE_CONFIG" ]]; then
      log "Config $DEFAULT_CONFIG not found; using example config $EXAMPLE_CONFIG"
      CONFIG_FILE="$EXAMPLE_CONFIG"
    else
      die "Config file not found: $CONFIG_FILE"
    fi
  fi

  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  AWS_REGION="${AWS_REGION:-us-east-1}"
  CLUSTER_NAME="${CLUSTER_NAME:-f5-guardrails-poc}"
  K8S_VERSION="${K8S_VERSION:-1.35}"
  NODEGROUP_NAME="${NODEGROUP_NAME:-guardrails-gpu-ng}"
  NODE_TYPE="${NODE_TYPE:-g5.4xlarge}"
  NODE_COUNT="${NODE_COUNT:-1}"
  NODE_MIN="${NODE_MIN:-1}"
  NODE_MAX="${NODE_MAX:-1}"
  NODE_VOLUME_SIZE="${NODE_VOLUME_SIZE:-150}"
  NODE_AMI_FAMILY="${NODE_AMI_FAMILY:-AmazonLinux2023}"
  VPC_NAT_MODE="${VPC_NAT_MODE:-Disable}"
  HOSTNAME="${HOSTNAME:-guardrails.f5demo.io}"
  ROUTE53_ZONE_NAME="${ROUTE53_ZONE_NAME:-${HOSTNAME#*.}}"
  ROUTE53_HOSTED_ZONE_ID="${ROUTE53_HOSTED_ZONE_ID:-}"
  HARBOR_REGISTRY="${HARBOR_REGISTRY:-harbor.calypsoai.app}"
  HARBOR_CREDENTIALS_FILE="${HARBOR_CREDENTIALS_FILE:-}"
  F5_LICENSE_FILE="${F5_LICENSE_FILE:-}"
  F5_NAMESPACE="${F5_NAMESPACE:-f5-ai-sec}"
  MODERATOR_NAMESPACE="${MODERATOR_NAMESPACE:-cai-moderator}"
  PREFECT_NAMESPACE="${PREFECT_NAMESPACE:-prefect}"
  INFERENCE_NAMESPACE="${INFERENCE_NAMESPACE:-f5-ai-sec-inference}"
  INGRESS_NAMESPACE="${INGRESS_NAMESPACE:-ingress-nginx}"
  OPERATOR_RELEASE="${OPERATOR_RELEASE:-f5-ai-security-operator}"
  OPERATOR_CHART="${OPERATOR_CHART:-oci://harbor.calypsoai.app/calypsoai/f5-ai-security-operator-helm}"
  OPERATOR_CHART_VERSION="${OPERATOR_CHART_VERSION:-1.4.1}"
  INGRESS_RELEASE="${INGRESS_RELEASE:-ingress-nginx}"
  INGRESS_CHART="${INGRESS_CHART:-ingress-nginx/ingress-nginx}"
  INGRESS_REPO_NAME="${INGRESS_REPO_NAME:-ingress-nginx}"
  INGRESS_REPO_URL="${INGRESS_REPO_URL:-https://kubernetes.github.io/ingress-nginx}"
  SECURITY_OPERATOR_NAME="${SECURITY_OPERATOR_NAME:-security-operator-demo}"
  POSTGRES_STORAGE_CLASS="${POSTGRES_STORAGE_CLASS:-gp2}"
  POSTGRES_PASSWORD_FILE="${POSTGRES_PASSWORD_FILE:-.secrets/postgres-password}"
  RECREATE_TLS_SECRET="${RECREATE_TLS_SECRET:-false}"
  CLEANUP_LEFTOVER_EBS_VOLUMES="${CLEANUP_LEFTOVER_EBS_VOLUMES:-true}"
}

run() {
  if [[ "$DRY_RUN" == true ]]; then
    printf '+ %s\n' "$*"
  else
    log "$*"
    "$@"
  fi
}

run_shell() {
  if [[ "$DRY_RUN" == true ]]; then
    printf '+ %s\n' "$*"
  else
    log "$*"
    bash -c "$*"
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

resolve_repo_path() {
  local path="$1"
  if [[ -z "$path" ]]; then
    printf '\n'
  elif [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$ROOT_DIR" "$path"
  fi
}

require_tools() {
  need_cmd aws
  need_cmd kubectl
  need_cmd helm
  need_cmd eksctl
  need_cmd openssl
  need_cmd python3
}

cluster_exists() {
  aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1
}

addon_exists() {
  local addon="$1"
  aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name "$addon" --region "$AWS_REGION" >/dev/null 2>&1
}

resolve_hosted_zone_id() {
  if [[ -n "$ROUTE53_HOSTED_ZONE_ID" ]]; then
    printf '%s\n' "$ROUTE53_HOSTED_ZONE_ID"
    return
  fi

  aws route53 list-hosted-zones-by-name \
    --dns-name "$ROUTE53_ZONE_NAME" \
    --query "HostedZones[?Name=='${ROUTE53_ZONE_NAME}.'].Id | [0]" \
    --output text | sed 's#^/hostedzone/##'
}

read_harbor_credentials() {
  if [[ -n "${HARBOR_USERNAME:-}" && -n "${HARBOR_PASSWORD:-}" ]]; then
    return
  fi

  local credentials_file
  credentials_file="$(resolve_repo_path "$HARBOR_CREDENTIALS_FILE")"
  [[ -n "$credentials_file" ]] || die "Set HARBOR_USERNAME/HARBOR_PASSWORD or HARBOR_CREDENTIALS_FILE"
  [[ -f "$credentials_file" ]] || die "Harbor credentials file not found: $credentials_file"

  HARBOR_USERNAME="$(grep -v '^[[:space:]]*$' "$credentials_file" | sed -n '1p')"
  HARBOR_PASSWORD="$(grep -v '^[[:space:]]*$' "$credentials_file" | sed -n '2p')"
  [[ -n "$HARBOR_USERNAME" && -n "$HARBOR_PASSWORD" ]] || die "Harbor credentials file must contain username and password on separate lines"
}

read_license() {
  if [[ -n "${F5_LICENSE_STRING:-}" ]]; then
    return
  fi

  local license_file
  license_file="$(resolve_repo_path "$F5_LICENSE_FILE")"
  [[ -n "$license_file" ]] || die "Set F5_LICENSE_STRING or F5_LICENSE_FILE"
  [[ -f "$license_file" ]] || die "F5 license file not found: $license_file"
  F5_LICENSE_STRING="$(tr -d '\r\n' < "$license_file")"
  [[ -n "$F5_LICENSE_STRING" ]] || die "F5 license string is empty"
}

ensure_secret_dir() {
  mkdir -p "$ROOT_DIR/.secrets"
  chmod 700 "$ROOT_DIR/.secrets"
}

get_or_create_postgres_password() {
  local path
  path="$(resolve_repo_path "$POSTGRES_PASSWORD_FILE")"
  ensure_secret_dir

  if [[ -f "$path" ]]; then
    POSTGRES_PASSWORD="$(< "$path")"
    [[ -n "$POSTGRES_PASSWORD" ]] || die "PostgreSQL password file is empty: $path"
    return
  fi

  POSTGRES_PASSWORD="$(python3 - <<'PY'
import secrets, string
alphabet = string.ascii_letters + string.digits
print(''.join(secrets.choice(alphabet) for _ in range(28)))
PY
)"
  umask 077
  printf '%s\n' "$POSTGRES_PASSWORD" > "$path"
}

create_cluster() {
  if [[ "$DRY_RUN" == true ]]; then
    run eksctl create cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --version "$K8S_VERSION" --managed --nodegroup-name "$NODEGROUP_NAME" --node-type "$NODE_TYPE" --nodes "$NODE_COUNT" --nodes-min "$NODE_MIN" --nodes-max "$NODE_MAX" --node-volume-size "$NODE_VOLUME_SIZE" --node-ami-family "$NODE_AMI_FAMILY" --install-nvidia-plugin --vpc-nat-mode "$VPC_NAT_MODE"
    return
  fi

  if cluster_exists; then
    log "EKS cluster already exists: $CLUSTER_NAME"
  else
    run eksctl create cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --version "$K8S_VERSION" --managed --nodegroup-name "$NODEGROUP_NAME" --node-type "$NODE_TYPE" --nodes "$NODE_COUNT" --nodes-min "$NODE_MIN" --nodes-max "$NODE_MAX" --node-volume-size "$NODE_VOLUME_SIZE" --node-ami-family "$NODE_AMI_FAMILY" --install-nvidia-plugin --vpc-nat-mode "$VPC_NAT_MODE"
  fi

  run aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"
}

install_storage_addons() {
  if [[ "$DRY_RUN" == true ]]; then
    run eksctl create addon --cluster "$CLUSTER_NAME" --region "$AWS_REGION" --name eks-pod-identity-agent --force
    run eksctl create addon --cluster "$CLUSTER_NAME" --region "$AWS_REGION" --name aws-ebs-csi-driver --auto-apply-pod-identity-associations --force
    run kubectl patch storageclass "$POSTGRES_STORAGE_CLASS" -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
    return
  fi

  if addon_exists eks-pod-identity-agent; then
    log "EKS add-on already exists: eks-pod-identity-agent"
  else
    run eksctl create addon --cluster "$CLUSTER_NAME" --region "$AWS_REGION" --name eks-pod-identity-agent --force
  fi

  if addon_exists aws-ebs-csi-driver; then
    log "EKS add-on already exists: aws-ebs-csi-driver"
  else
    run eksctl create addon --cluster "$CLUSTER_NAME" --region "$AWS_REGION" --name aws-ebs-csi-driver --auto-apply-pod-identity-associations --force
  fi

  run kubectl patch storageclass "$POSTGRES_STORAGE_CLASS" -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
}

create_harbor_secret() {
  if [[ "$DRY_RUN" == true ]]; then
    run kubectl create namespace "$F5_NAMESPACE" --dry-run=client -o yaml
    printf '+ kubectl apply -f -\n'
    printf '+ kubectl create secret generic regcred -n %s --from-file=.dockerconfigjson=<generated> --type=kubernetes.io/dockerconfigjson\n' "$F5_NAMESPACE"
    return
  fi

  read_harbor_credentials
  kubectl create namespace "$F5_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  local tmpdir auth
  tmpdir="$(mktemp -d)"
  auth="$(printf '%s:%s' "$HARBOR_USERNAME" "$HARBOR_PASSWORD" | base64 | tr -d '\n')"
  HARBOR_USERNAME="$HARBOR_USERNAME" HARBOR_PASSWORD="$HARBOR_PASSWORD" HARBOR_REGISTRY="$HARBOR_REGISTRY" HARBOR_AUTH="$auth" python3 - "$tmpdir/config.json" <<'PY'
import json, os, sys
path = sys.argv[1]
registry = os.environ["HARBOR_REGISTRY"]
config = {
    "auths": {
        registry: {
            "username": os.environ["HARBOR_USERNAME"],
            "password": os.environ["HARBOR_PASSWORD"],
            "auth": os.environ["HARBOR_AUTH"],
        }
    }
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(config, f)
PY
  kubectl delete secret regcred -n "$F5_NAMESPACE" --ignore-not-found
  kubectl create secret generic regcred -n "$F5_NAMESPACE" \
    --from-file=.dockerconfigjson="$tmpdir/config.json" \
    --type=kubernetes.io/dockerconfigjson
  rm -rf "$tmpdir"
}

helm_login_harbor() {
  if [[ "$DRY_RUN" == true ]]; then
    printf '+ helm registry login %s --username <harbor-user> --password-stdin\n' "$HARBOR_REGISTRY"
    return
  fi
  read_harbor_credentials
  printf '%s\n' "$HARBOR_PASSWORD" | helm registry login "$HARBOR_REGISTRY" --username "$HARBOR_USERNAME" --password-stdin
}

install_operator() {
  helm_login_harbor
  run helm upgrade --install "$OPERATOR_RELEASE" "$OPERATOR_CHART" --version "$OPERATOR_CHART_VERSION" -n "$F5_NAMESPACE"
  run kubectl rollout status -n "$F5_NAMESPACE" deploy/controller-manager --timeout=180s
}

apply_security_operator() {
  if [[ "$DRY_RUN" == true ]]; then
    printf '+ kubectl apply -f <SecurityOperator manifest for %s>\n' "$SECURITY_OPERATOR_NAME"
    printf '  SecurityOperator manifest: Guardrails enabled, Red Team disabled, in-cluster PostgreSQL enabled, CAI_MODERATOR_BASE_URL=https://%s\n' "$HOSTNAME"
    return
  fi

  read_license
  get_or_create_postgres_password
  local manifest
  manifest="$(mktemp)"
  MANIFEST_PATH="$manifest" \
  SECURITY_OPERATOR_NAME="$SECURITY_OPERATOR_NAME" \
  F5_NAMESPACE="$F5_NAMESPACE" \
  HOSTNAME="$HOSTNAME" \
  POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  F5_LICENSE_STRING="$F5_LICENSE_STRING" \
  python3 - <<'PY'
import os
from pathlib import Path

manifest = f"""apiVersion: ai.security.f5.com/v1alpha1
kind: SecurityOperator
metadata:
  name: {os.environ['SECURITY_OPERATOR_NAME']}
  namespace: {os.environ['F5_NAMESPACE']}
spec:
  registryAuth:
    existingSecret: "regcred"
  postgresql:
    enabled: true
    values:
      postgresql:
        auth:
          password: "{os.environ['POSTGRES_PASSWORD']}"
  jobManager:
    enabled: true
  moderator:
    enabled: true
    values:
      env:
        CAI_MODERATOR_BASE_URL: https://{os.environ['HOSTNAME']}
      secrets:
        CAI_MODERATOR_DB_ADMIN_PASSWORD: "{os.environ['POSTGRES_PASSWORD']}"
        CAI_MODERATOR_DEFAULT_LICENSE: "{os.environ['F5_LICENSE_STRING']}"
  inference:
    enabled: true
    values:
      inference:
        guardrails:
          enabled: true
        redteam:
          enabled: false
"""
Path(os.environ["MANIFEST_PATH"]).write_text(manifest, encoding="utf-8")
PY
  kubectl apply -f "$manifest"
  rm -f "$manifest"
}

wait_for_app() {
  if [[ "$DRY_RUN" == true ]]; then
    run kubectl wait --for=condition=ready pod -n "$MODERATOR_NAMESPACE" --all --timeout=900s
    run kubectl wait --for=condition=ready pod -n "$INFERENCE_NAMESPACE" --all --timeout=1200s
    return
  fi

  log "Waiting for F5 namespaces to exist"
  for ns in "$MODERATOR_NAMESPACE" "$PREFECT_NAMESPACE" "$INFERENCE_NAMESPACE"; do
    until kubectl get namespace "$ns" >/dev/null 2>&1; do sleep 10; done
  done

  log "Waiting for Moderator, PostgreSQL, and inference pods"
  kubectl wait --for=condition=ready pod -n "$MODERATOR_NAMESPACE" --all --timeout=900s || true
  kubectl wait --for=condition=ready pod -n "$INFERENCE_NAMESPACE" --all --timeout=1200s || true
}

fix_prefect_workflows() {
  if [[ "$DRY_RUN" == true ]]; then
    printf '+ wait for http://prefect-server.%s.svc.cluster.local:4200/api/health\n' "$PREFECT_NAMESPACE"
    run kubectl delete job -n "$PREFECT_NAMESPACE" -l job-name --ignore-not-found
    printf '+ kubectl create job -n %s cai-workflows-manual-<timestamp> --from=cronjob/cai-workflows\n' "$PREFECT_NAMESPACE"
    printf '  cai-workflows-manual job waits for Prefect API and registers deployments\n'
    return
  fi

  log "Waiting for Prefect API health"
  until kubectl exec -n "$PREFECT_NAMESPACE" deploy/prefect-server -- /bin/sh -c \
    'python - <<PY
import urllib.request
urllib.request.urlopen("http://prefect-server.prefect.svc.cluster.local:4200/api/health", timeout=5)
PY' >/dev/null 2>&1; do
    sleep 10
  done

  kubectl delete job -n "$PREFECT_NAMESPACE" -l batch.kubernetes.io/job-name --ignore-not-found || true
  local job_name="cai-workflows-manual-$(date +%Y%m%d-%H%M%S)"
  run kubectl create job -n "$PREFECT_NAMESPACE" "$job_name" --from=cronjob/cai-workflows
  run kubectl wait --for=condition=complete job/"$job_name" -n "$PREFECT_NAMESPACE" --timeout=600s
  run kubectl rollout status -n "$PREFECT_NAMESPACE" deploy/prefect-worker --timeout=300s
}

install_ingress() {
  run helm repo add "$INGRESS_REPO_NAME" "$INGRESS_REPO_URL" --force-update
  run helm repo update "$INGRESS_REPO_NAME"
  run helm upgrade --install "$INGRESS_RELEASE" "$INGRESS_CHART" --namespace "$INGRESS_NAMESPACE" --create-namespace --set 'controller.service.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-type=nlb' --set 'controller.service.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-scheme=internet-facing' --set controller.service.externalTrafficPolicy=Local
  run kubectl rollout status -n "$INGRESS_NAMESPACE" deploy/ingress-nginx-controller --timeout=300s
}

create_tls_secret() {
  if [[ "$DRY_RUN" == true ]]; then
    printf '+ create self-signed TLS secret cai-moderator-tls for %s\n' "$HOSTNAME"
    return
  fi

  if [[ "$RECREATE_TLS_SECRET" != "true" ]] && kubectl get secret cai-moderator-tls -n "$MODERATOR_NAMESPACE" >/dev/null 2>&1; then
    log "TLS secret already exists: $MODERATOR_NAMESPACE/cai-moderator-tls"
    return
  fi

  local tmpdir
  tmpdir="$(mktemp -d)"
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "$tmpdir/tls.key" \
    -out "$tmpdir/tls.crt" \
    -subj "/CN=$HOSTNAME" \
    -addext "subjectAltName=DNS:$HOSTNAME" >/dev/null 2>&1
  kubectl create secret tls cai-moderator-tls \
    -n "$MODERATOR_NAMESPACE" \
    --cert="$tmpdir/tls.crt" \
    --key="$tmpdir/tls.key" \
    --dry-run=client \
    -o yaml | kubectl apply -f -
  rm -rf "$tmpdir"
}

apply_ingress() {
  if [[ "$DRY_RUN" == true ]]; then
    printf '+ kubectl apply -f <cai-moderator-ingress for %s>\n' "$HOSTNAME"
    printf '  cai-moderator-ingress routes /auth to 8080 and / to 5500\n'
    return
  fi

  local manifest
  manifest="$(mktemp)"
  cat > "$manifest" <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cai-moderator-ingress
  namespace: $MODERATOR_NAMESPACE
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-http-version: "1.1"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - $HOSTNAME
    secretName: cai-moderator-tls
  rules:
  - host: $HOSTNAME
    http:
      paths:
      - path: /auth
        pathType: Prefix
        backend:
          service:
            name: cai-moderator
            port:
              number: 8080
      - path: /
        pathType: Prefix
        backend:
          service:
            name: cai-moderator
            port:
              number: 5500
YAML
  kubectl apply -f "$manifest"
  rm -f "$manifest"
}

get_ingress_lb() {
  kubectl get svc -n "$INGRESS_NAMESPACE" ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
}

wait_for_ingress_lb() {
  if [[ "$DRY_RUN" == true ]]; then
    printf '+ wait for ingress-nginx load balancer hostname\n'
    return
  fi

  log "Waiting for ingress-nginx load balancer hostname"
  local lb=""
  for _ in {1..60}; do
    lb="$(get_ingress_lb || true)"
    if [[ -n "$lb" ]]; then
      printf '%s\n' "$lb"
      return
    fi
    sleep 10
  done
  die "Timed out waiting for ingress-nginx load balancer hostname"
}

route53_upsert() {
  local lb="$1"
  if [[ "$DRY_RUN" == true ]]; then
    printf '+ route53 UPSERT %s -> <ingress-nginx-load-balancer>\n' "$HOSTNAME"
    return
  fi

  local zone_id change_file
  zone_id="$(resolve_hosted_zone_id)"
  [[ -n "$zone_id" && "$zone_id" != "None" ]] || die "Could not resolve Route 53 hosted zone for $ROUTE53_ZONE_NAME"
  change_file="$(mktemp)"
  HOSTNAME="$HOSTNAME" LB_HOSTNAME="$lb" python3 - "$change_file" <<'PY'
import json, os, sys
change = {
    "Comment": "Point Guardrails PoC hostname to ingress-nginx load balancer",
    "Changes": [{
        "Action": "UPSERT",
        "ResourceRecordSet": {
            "Name": os.environ["HOSTNAME"].rstrip(".") + ".",
            "Type": "CNAME",
            "TTL": 60,
            "ResourceRecords": [{"Value": os.environ["LB_HOSTNAME"]}],
        },
    }],
}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(change, f)
PY
  aws route53 change-resource-record-sets --hosted-zone-id "$zone_id" --change-batch "file://$change_file"
  rm -f "$change_file"
}

route53_delete() {
  if [[ "$DRY_RUN" == true ]]; then
    printf '+ route53 DELETE %s\n' "$HOSTNAME"
    return
  fi

  local zone_id current change_file
  zone_id="$(resolve_hosted_zone_id)"
  [[ -n "$zone_id" && "$zone_id" != "None" ]] || { log "Route 53 hosted zone not found; skipping DNS delete"; return; }
  current="$(aws route53 list-resource-record-sets \
    --hosted-zone-id "$zone_id" \
    --query "ResourceRecordSets[?Name=='${HOSTNAME}.' && Type=='CNAME'] | [0].ResourceRecords[0].Value" \
    --output text)"
  if [[ -z "$current" || "$current" == "None" ]]; then
    log "Route 53 CNAME not found for $HOSTNAME; skipping DNS delete"
    return
  fi

  change_file="$(mktemp)"
  HOSTNAME="$HOSTNAME" LB_HOSTNAME="$current" python3 - "$change_file" <<'PY'
import json, os, sys
change = {
    "Comment": "Delete Guardrails PoC hostname",
    "Changes": [{
        "Action": "DELETE",
        "ResourceRecordSet": {
            "Name": os.environ["HOSTNAME"].rstrip(".") + ".",
            "Type": "CNAME",
            "TTL": 60,
            "ResourceRecords": [{"Value": os.environ["LB_HOSTNAME"]}],
        },
    }],
}

with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(change, f)
PY
  aws route53 change-resource-record-sets --hosted-zone-id "$zone_id" --change-batch "file://$change_file"
  rm -f "$change_file"
}

cleanup_leftover_ebs_volumes() {
  if [[ "$CLEANUP_LEFTOVER_EBS_VOLUMES" != "true" ]]; then
    log "Skipping leftover EBS volume cleanup because CLEANUP_LEFTOVER_EBS_VOLUMES=$CLEANUP_LEFTOVER_EBS_VOLUMES"
    return
  fi

  if [[ "$DRY_RUN" == true ]]; then
    printf '+ find available EBS volumes tagged kubernetes.io/cluster/%s=owned\n' "$CLUSTER_NAME"
    printf '+ aws ec2 delete-volume --region %s --volume-id <leftover-pvc-volume>\n' "$AWS_REGION"
    return
  fi

  local volumes
  volumes="$(aws ec2 describe-volumes \
    --region "$AWS_REGION" \
    --filters "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned" "Name=status,Values=available" \
    --query 'Volumes[].VolumeId' \
    --output text)"

  if [[ -z "$volumes" || "$volumes" == "None" ]]; then
    log "No available leftover EBS volumes found for cluster tag kubernetes.io/cluster/$CLUSTER_NAME=owned"
    return
  fi

  for volume_id in $volumes; do
    log "Deleting leftover EBS volume $volume_id"
    aws ec2 delete-volume --region "$AWS_REGION" --volume-id "$volume_id"
  done
}

print_dns_status() {
  local zone_id current
  zone_id="$(resolve_hosted_zone_id)"
  if [[ -z "$zone_id" || "$zone_id" == "None" ]]; then
    printf 'DNS record:           unknown (hosted zone %s not found)\n' "$ROUTE53_ZONE_NAME"
    return
  fi

  current="$(aws route53 list-resource-record-sets \
    --hosted-zone-id "$zone_id" \
    --query "ResourceRecordSets[?Name=='${HOSTNAME}.' && Type=='CNAME'] | [0].ResourceRecords[0].Value" \
    --output text)"
  if [[ -z "$current" || "$current" == "None" ]]; then
    printf 'DNS record:           deleted (%s not present)\n' "$HOSTNAME"
  else
    printf 'DNS record:           present (%s -> %s)\n' "$HOSTNAME" "$current"
  fi
}

print_leftover_volume_status() {
  local volumes
  volumes="$(aws ec2 describe-volumes \
    --region "$AWS_REGION" \
    --filters "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned" "Name=status,Values=available,in-use,creating,deleting" \
    --query 'Volumes[].[VolumeId,State,Size,Tags[?Key==`Name`].Value|[0]]' \
    --output text)"

  if [[ -z "$volumes" || "$volumes" == "None" ]]; then
    printf 'EBS volumes:          none found with cluster-owned tag\n'
  else
    printf 'EBS volumes:          leftovers found\n'
    printf '%s\n' "$volumes" | sed 's/^/  /'
  fi
}

status_stopped() {
  printf '\nGuardrails PoC status\n'
  printf '=====================\n'
  printf 'Environment:          stopped\n'
  printf 'EKS cluster:          not found (%s in %s)\n' "$CLUSTER_NAME" "$AWS_REGION"
  print_dns_status
  print_leftover_volume_status
  printf 'Kubernetes resources: skipped because the EKS cluster is deleted\n'
  printf 'Public URL:           offline (https://%s)\n' "$HOSTNAME"
  printf '\nNext actions:\n'
  printf '  Start again:        ./scripts/guardrails-poc.sh up\n'
  printf '  Re-check status:    ./scripts/guardrails-poc.sh status\n'
}

verify_public_url() {
  if [[ "$DRY_RUN" == true ]]; then
    run curl -k -I --max-time 20 "https://$HOSTNAME/"
    run curl -k -I --max-time 20 "https://$HOSTNAME/auth/"
    return
  fi

  log "Waiting for public URL to respond"
  for _ in {1..60}; do
    if curl -k -fsSI --max-time 10 "https://$HOSTNAME/" >/dev/null 2>&1; then
      break
    fi
    sleep 10
  done
  run curl -k -I --max-time 20 "https://$HOSTNAME/"
  run curl -k -I --max-time 20 "https://$HOSTNAME/auth/"
}

do_up() {
  require_tools
  create_cluster
  install_storage_addons
  create_harbor_secret
  install_operator
  apply_security_operator
  wait_for_app
  fix_prefect_workflows
  install_ingress
  create_tls_secret
  apply_ingress
  local lb
  lb="$(wait_for_ingress_lb | tail -1)"
  route53_upsert "$lb"
  verify_public_url
  status
}

do_down() {
  require_tools
  if [[ "$ASSUME_YES" != true && "$DRY_RUN" != true ]]; then
    printf 'This will delete Route 53 DNS and EKS cluster %s in %s. Type DELETE to continue: ' "$CLUSTER_NAME" "$AWS_REGION"
    read -r answer
    [[ "$answer" == "DELETE" ]] || die "Aborted"
  fi

  route53_delete
  if [[ "$DRY_RUN" == true ]]; then
    run eksctl delete cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --wait
  elif cluster_exists; then
    run eksctl delete cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --wait
  else
    log "EKS cluster not found: $CLUSTER_NAME; skipping cluster delete"
  fi
  cleanup_leftover_ebs_volumes
}

status() {
  if [[ "$DRY_RUN" == true ]]; then
    run aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION"
    run kubectl get nodes -o wide
    run kubectl get pods -n "$F5_NAMESPACE" -o wide
    run kubectl get pods -n "$MODERATOR_NAMESPACE" -o wide
    run kubectl get pods -n "$PREFECT_NAMESPACE" -o wide
    run kubectl get pods -n "$INFERENCE_NAMESPACE" -o wide
    run kubectl get ingress -n "$MODERATOR_NAMESPACE" -o wide
    return
  fi

  if ! cluster_exists; then
    status_stopped
    return
  fi

  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null

  log "AWS cluster"
  aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.[name,status,version,endpoint]' --output table || true
  log "Kubernetes nodes"
  kubectl get nodes -o wide || true
  for ns in "$F5_NAMESPACE" "$MODERATOR_NAMESPACE" "$PREFECT_NAMESPACE" "$INFERENCE_NAMESPACE" "$INGRESS_NAMESPACE"; do
    log "Pods: $ns"
    kubectl get pods -n "$ns" -o wide || true
  done
  log "Ingress"
  kubectl get ingress -n "$MODERATOR_NAMESPACE" -o wide || true
  log "URL: https://$HOSTNAME"
}

load_config

case "$ACTION" in
  up) do_up ;;
  down) do_down ;;
  status) require_tools; status ;;
  *) die "Unknown action: $ACTION" ;;
esac
