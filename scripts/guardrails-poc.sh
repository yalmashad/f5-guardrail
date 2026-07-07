#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_CONFIG="$ROOT_DIR/config/guardrails-poc.env"
EXAMPLE_CONFIG="$ROOT_DIR/config/guardrails-poc.env.example"

CONFIG_FILE="$DEFAULT_CONFIG"
DRY_RUN=false
ASSUME_YES=false
PREFLIGHT_FAILURES=0
COLOR_RESET=""
COLOR_BOLD=""
COLOR_GREEN=""
COLOR_YELLOW=""
COLOR_RED=""

init_colors() {
  if [[ -n "${NO_COLOR:-}" ]]; then
    return
  fi

  if [[ -t 1 || "${FORCE_COLOR:-}" == "1" || "${CLICOLOR_FORCE:-}" == "1" ]]; then
    COLOR_RESET=$'\033[0m'
    COLOR_BOLD=$'\033[1m'
    COLOR_GREEN=$'\033[32m'
    COLOR_YELLOW=$'\033[33m'
    COLOR_RED=$'\033[31m'
  fi
}

color_text() {
  local color="$1"
  shift
  if [[ -n "$color" ]]; then
    printf '%s%s%s' "$color" "$*" "$COLOR_RESET"
  else
    printf '%s' "$*"
  fi
}

color_status_value() {
  local value="$1"
  local lower
  lower="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"

  case "$lower" in
    missing*|failed*|error*|not\ found*)
      color_text "$COLOR_RED" "$value"
      ;;
    warning*|pending*|unknown*|stopped*|offline*|deleted*|not\ reachable*)
      color_text "$COLOR_YELLOW" "$value"
      ;;
    ready*|online*|present*|running*|active*|enabled*|*' ready'*|*' none found'*)
      color_text "$COLOR_GREEN" "$value"
      ;;
    disabled*)
      color_text "$COLOR_YELLOW" "$value"
      ;;
    *)
      printf '%s' "$value"
      ;;
  esac
}

print_heading() {
  printf '\n%s\n' "$(color_text "$COLOR_BOLD" "$1")"
  printf '%s\n' "$2"
}

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
  scripts/guardrails-poc.sh [--config FILE] preflight
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
  scripts/guardrails-poc.sh preflight
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
    preflight|up|down|status)
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
  GUARDRAIL_NODEGROUP_NAME="${GUARDRAIL_NODEGROUP_NAME:-guardrails-gpu-ng}"
  GUARDRAIL_NODE_TYPE="${GUARDRAIL_NODE_TYPE:-g5.4xlarge}"
  GUARDRAIL_NODE_COUNT="${GUARDRAIL_NODE_COUNT:-1}"
  GUARDRAIL_NODE_MIN="${GUARDRAIL_NODE_MIN:-1}"
  GUARDRAIL_NODE_MAX="${GUARDRAIL_NODE_MAX:-1}"
  GUARDRAIL_NODE_VOLUME_SIZE="${GUARDRAIL_NODE_VOLUME_SIZE:-150}"
  NODE_AMI_FAMILY="${NODE_AMI_FAMILY:-AmazonLinux2023}"
  VPC_NAT_MODE="${VPC_NAT_MODE:-Disable}"
  HOSTNAME="${HOSTNAME:-guardrails.f5demo.io}"
  ROUTE53_ENABLED="${ROUTE53_ENABLED:-false}"
  ROUTE53_ZONE_NAME="${ROUTE53_ZONE_NAME:-${HOSTNAME#*.}}"
  ROUTE53_HOSTED_ZONE_ID="${ROUTE53_HOSTED_ZONE_ID:-}"
  GUARDRAILS_DEFAULT_USERNAME="${GUARDRAILS_DEFAULT_USERNAME:-admin}"
  GUARDRAILS_DEFAULT_PASSWORD="${GUARDRAILS_DEFAULT_PASSWORD:-pass}"
  GUARDRAILS_AUTH_REALMS="${GUARDRAILS_AUTH_REALMS:-master calypsoai}"
  ENABLE_RED_TEAM="${ENABLE_RED_TEAM:-false}"
  RED_TEAM_NODEGROUP_NAME="${RED_TEAM_NODEGROUP_NAME:-redteam-gpu-ng}"
  RED_TEAM_NODE_TYPE="${RED_TEAM_NODE_TYPE:-g6e.2xlarge}"
  RED_TEAM_NODE_COUNT="${RED_TEAM_NODE_COUNT:-1}"
  RED_TEAM_NODE_MIN="${RED_TEAM_NODE_MIN:-1}"
  RED_TEAM_NODE_MAX="${RED_TEAM_NODE_MAX:-1}"
  RED_TEAM_NODE_VOLUME_SIZE="${RED_TEAM_NODE_VOLUME_SIZE:-150}"
  HARBOR_REGISTRY="${HARBOR_REGISTRY:-harbor.calypsoai.app}"
  HARBOR_CREDENTIALS_FILE="${HARBOR_CREDENTIALS_FILE:-}"
  F5_LICENSE_FILE="${F5_LICENSE_FILE:-}"
  F5_NAMESPACE="${F5_NAMESPACE:-f5-ai-sec}"
  MODERATOR_NAMESPACE="${MODERATOR_NAMESPACE:-cai-moderator}"
  PREFECT_NAMESPACE="${PREFECT_NAMESPACE:-prefect}"
  INFERENCE_NAMESPACE="${INFERENCE_NAMESPACE:-f5-ai-sec-inference}"
  INGRESS_NAMESPACE="${INGRESS_NAMESPACE:-nginx-ingress}"
  OPERATOR_RELEASE="${OPERATOR_RELEASE:-f5-ai-security-operator}"
  OPERATOR_CHART="${OPERATOR_CHART:-oci://harbor.calypsoai.app/calypsoai/f5-ai-security-operator-helm}"
  OPERATOR_CHART_VERSION="${OPERATOR_CHART_VERSION:-1.4.1}"
  INGRESS_RELEASE="${INGRESS_RELEASE:-nginx-ingress}"
  INGRESS_CHART="${INGRESS_CHART:-nginx-stable/nginx-ingress}"
  INGRESS_REPO_NAME="${INGRESS_REPO_NAME:-nginx-stable}"
  INGRESS_REPO_URL="${INGRESS_REPO_URL:-https://helm.nginx.com/stable}"
  INGRESS_CONTROLLER_SERVICE="${INGRESS_CONTROLLER_SERVICE:-nginx-ingress-controller}"
  INGRESS_CONTROLLER_DEPLOYMENT="${INGRESS_CONTROLLER_DEPLOYMENT:-nginx-ingress-controller}"
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
  need_cmd curl
}

preflight_ok() {
  printf '  %s   %s\n' "$(color_text "$COLOR_GREEN" "[OK]")" "$*"
}

preflight_warn() {
  printf '  %s %s\n' "$(color_text "$COLOR_YELLOW" "[WARN]")" "$*"
}

preflight_fail() {
  PREFLIGHT_FAILURES=$((PREFLIGHT_FAILURES + 1))
  printf '  %s %s\n' "$(color_text "$COLOR_RED" "[FAIL]")" "$*"
}

command_version() {
  case "$1" in
    aws) aws --version 2>&1 | awk '{print $1}' ;;
    kubectl) kubectl version --client=true 2>/dev/null | head -1 ;;
    helm) helm version --short 2>/dev/null ;;
    eksctl) eksctl version 2>/dev/null ;;
    openssl) openssl version 2>/dev/null ;;
    python3) python3 --version 2>&1 ;;
    curl) curl --version 2>/dev/null | head -1 ;;
    *) "$1" --version 2>/dev/null | head -1 ;;
  esac
}

check_command() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    preflight_ok "$cmd found: $(command_version "$cmd")"
  else
    preflight_fail "$cmd is not installed or not in PATH"
  fi
}

check_secret_file() {
  local label="$1"
  local configured_path="$2"
  local env_name="$3"
  local resolved_path
  resolved_path="$(resolve_repo_path "$configured_path")"

  if [[ -n "${!env_name:-}" ]]; then
    preflight_ok "$label supplied by environment variable $env_name"
    return
  fi

  if [[ -z "$resolved_path" ]]; then
    preflight_fail "$label is missing. Set $env_name or configure a file path."
  elif [[ -f "$resolved_path" ]]; then
    if [[ -s "$resolved_path" ]]; then
      preflight_ok "$label file exists: ${configured_path}"
    else
      preflight_fail "$label file is empty: ${configured_path}"
    fi
  else
    preflight_fail "$label file not found: ${configured_path}"
  fi
}

check_harbor_secret_input() {
  local credentials_file
  credentials_file="$(resolve_repo_path "$HARBOR_CREDENTIALS_FILE")"

  if [[ -n "${HARBOR_USERNAME:-}" || -n "${HARBOR_PASSWORD:-}" ]]; then
    if [[ -n "${HARBOR_USERNAME:-}" && -n "${HARBOR_PASSWORD:-}" ]]; then
      preflight_ok "Harbor credentials supplied by HARBOR_USERNAME/HARBOR_PASSWORD"
    else
      preflight_fail "Harbor environment variables are incomplete. Set both HARBOR_USERNAME and HARBOR_PASSWORD."
    fi
    return
  fi

  if [[ -z "$credentials_file" ]]; then
    preflight_fail "Harbor credentials are missing. Set HARBOR_USERNAME/HARBOR_PASSWORD or HARBOR_CREDENTIALS_FILE."
  elif [[ -f "$credentials_file" ]]; then
    if [[ -s "$credentials_file" ]]; then
      preflight_ok "Harbor credentials file exists: ${HARBOR_CREDENTIALS_FILE}"
    else
      preflight_fail "Harbor credentials file is empty: ${HARBOR_CREDENTIALS_FILE}"
    fi
  else
    preflight_fail "Harbor credentials file not found: ${HARBOR_CREDENTIALS_FILE}"
  fi
}

check_harbor_file_format() {
  if [[ -n "${HARBOR_USERNAME:-}" && -n "${HARBOR_PASSWORD:-}" ]]; then
    return
  fi

  local credentials_file username password
  credentials_file="$(resolve_repo_path "$HARBOR_CREDENTIALS_FILE")"
  [[ -f "$credentials_file" ]] || return 0
  username="$(grep -v '^[[:space:]]*$' "$credentials_file" | sed -n '1p')"
  password="$(grep -v '^[[:space:]]*$' "$credentials_file" | sed -n '2p')"
  if [[ -n "$username" && -n "$password" ]]; then
    preflight_ok "Harbor credentials file has username and password lines"
  else
    preflight_fail "Harbor credentials file must contain username on line 1 and password on line 2"
  fi
}

check_aws_credentials() {
  local identity account arn
  if ! identity="$(aws sts get-caller-identity --output json 2>/dev/null)"; then
    preflight_fail "AWS credentials are not working. Run aws configure."
    return
  fi

  account="$(printf '%s' "$identity" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Account","unknown"))')"
  arn="$(printf '%s' "$identity" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Arn","unknown"))')"
  preflight_ok "AWS identity works: account ${account}, principal ${arn}"
}

check_aws_region() {
  if aws ec2 describe-regions --region "$AWS_REGION" --region-names "$AWS_REGION" >/dev/null 2>&1; then
    preflight_ok "AWS region is reachable: $AWS_REGION"
  else
    preflight_fail "AWS region is not reachable or not enabled: $AWS_REGION"
  fi
}

check_route53_zone() {
  if [[ "$ROUTE53_ENABLED" != "true" ]]; then
    preflight_ok "Route 53 management disabled; skipping hosted zone lookup"
    return
  fi

  local zone_id
  if ! zone_id="$(resolve_hosted_zone_id 2>/dev/null)"; then
    preflight_fail "Unable to query Route 53 hosted zone for $ROUTE53_ZONE_NAME"
    return
  fi

  if [[ -n "$zone_id" && "$zone_id" != "None" ]]; then
    preflight_ok "Route 53 hosted zone found for $ROUTE53_ZONE_NAME: $zone_id"
  else
    preflight_fail "Route 53 hosted zone not found for $ROUTE53_ZONE_NAME"
  fi
}

check_instance_offering_for() {
  local label="$1"
  local instance_type="$2"
  local count
  count="$(aws ec2 describe-instance-type-offerings \
    --region "$AWS_REGION" \
    --location-type availability-zone \
    --filters "Name=instance-type,Values=$instance_type" \
    --query 'length(InstanceTypeOfferings)' \
    --output text 2>/dev/null || printf '0')"
  if [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]]; then
    preflight_ok "$label instance type $instance_type is offered in $AWS_REGION ($count AZs)"
  else
    preflight_fail "$label instance type $instance_type does not appear available in $AWS_REGION"
  fi
}

check_instance_offerings() {
  check_instance_offering_for "Guardrails" "$GUARDRAIL_NODE_TYPE"
  if [[ "$ENABLE_RED_TEAM" == "true" ]]; then
    check_instance_offering_for "Red Team" "$RED_TEAM_NODE_TYPE"
  fi
}

check_gpu_quota() {
  local quotas quota
  quotas="$(aws service-quotas list-service-quotas \
    --service-code ec2 \
    --region "$AWS_REGION" \
    --output json 2>/dev/null || true)"
  quota="$(QUOTAS_JSON="$quotas" python3 - <<'PY' 2>/dev/null || true
import json, os
try:
    data = json.loads(os.environ.get("QUOTAS_JSON", ""))
except Exception:
    print("")
    raise SystemExit
for quota in data.get("Quotas", []):
    if quota.get("QuotaCode") == "L-DB2E81BA":
        print(quota.get("Value", ""))
        break
PY
)"
  if [[ -z "$quota" || "$quota" == "None" ]]; then
    preflight_warn "Could not read EC2 G/VT On-Demand quota; continuing because AWS will enforce quota during node creation"
  else
    preflight_ok "EC2 G/VT On-Demand quota is visible: ${quota} vCPUs"
  fi
}

check_eksctl_cluster_config() {
  if cluster_exists; then
    preflight_ok "EKS cluster already exists; up will reuse it: $CLUSTER_NAME"
    return
  fi

  if eksctl create cluster \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --version "$K8S_VERSION" \
    --managed \
    --nodegroup-name "$GUARDRAIL_NODEGROUP_NAME" \
    --node-type "$GUARDRAIL_NODE_TYPE" \
    --nodes "$GUARDRAIL_NODE_COUNT" \
    --nodes-min "$GUARDRAIL_NODE_MIN" \
    --nodes-max "$GUARDRAIL_NODE_MAX" \
    --node-volume-size "$GUARDRAIL_NODE_VOLUME_SIZE" \
    --node-ami-family "$NODE_AMI_FAMILY" \
    --vpc-nat-mode "$VPC_NAT_MODE" \
    --dry-run >/dev/null 2>&1; then
    preflight_ok "eksctl accepts the cluster configuration for Kubernetes $K8S_VERSION"
  else
    preflight_fail "eksctl dry-run failed. Check eksctl version, Kubernetes version $K8S_VERSION, AWS credentials, and cluster config."
  fi
}

check_harbor_login() {
  local credentials_file username password

  if [[ -n "${HARBOR_USERNAME:-}" && -n "${HARBOR_PASSWORD:-}" ]]; then
    username="$HARBOR_USERNAME"
    password="$HARBOR_PASSWORD"
  else
    credentials_file="$(resolve_repo_path "$HARBOR_CREDENTIALS_FILE")"
    if [[ ! -f "$credentials_file" ]]; then
      preflight_warn "Skipping Harbor login validation because credentials are missing"
      return
    fi
    username="$(grep -v '^[[:space:]]*$' "$credentials_file" | sed -n '1p')"
    password="$(grep -v '^[[:space:]]*$' "$credentials_file" | sed -n '2p')"
  fi

  if [[ -z "$username" || -z "$password" ]]; then
    preflight_warn "Skipping Harbor login validation because credentials are incomplete"
    return
  fi

  if printf '%s\n' "$password" | helm registry login "$HARBOR_REGISTRY" --username "$username" --password-stdin >/dev/null 2>&1; then
    preflight_ok "Harbor registry login succeeded for $HARBOR_REGISTRY"
  else
    preflight_fail "Harbor registry login failed for $HARBOR_REGISTRY"
  fi
}

check_license_string() {
  local license_file

  if [[ -n "${F5_LICENSE_STRING:-}" ]]; then
    preflight_ok "F5 license string is present"
    return
  fi

  license_file="$(resolve_repo_path "$F5_LICENSE_FILE")"
  if [[ ! -f "$license_file" ]]; then
    preflight_warn "Skipping license content validation because license file is missing"
    return
  fi

  if [[ -s "$license_file" && -n "$(tr -d '\r\n' < "$license_file")" ]]; then
    preflight_ok "F5 license string is present"
  else
    preflight_fail "F5 license file is empty"
  fi
}

preflight_up() {
  local mode="${1:-deploy}"

  if [[ "$DRY_RUN" == true ]]; then
    printf '\nPreflight checks skipped in --dry-run mode. Dry-run prints planned commands only.\n\n'
    return
  fi

  PREFLIGHT_FAILURES=0
  print_heading "Guardrails PoC preflight" "========================"
  printf 'Config file:            %s\n' "$CONFIG_FILE"
  printf 'Cluster:                %s (%s)\n' "$CLUSTER_NAME" "$AWS_REGION"
  printf 'Guardrails node group:  %s (%s x %s)\n' "$GUARDRAIL_NODEGROUP_NAME" "$GUARDRAIL_NODE_COUNT" "$GUARDRAIL_NODE_TYPE"
  if [[ "$ENABLE_RED_TEAM" == "true" ]]; then
    printf 'Red Team node group:    %s (%s x %s)\n' "$RED_TEAM_NODEGROUP_NAME" "$RED_TEAM_NODE_COUNT" "$RED_TEAM_NODE_TYPE"
  fi
  printf 'Hostname:               %s\n' "$HOSTNAME"
  printf 'Route 53 managed:       %s\n' "$ROUTE53_ENABLED"
  printf 'Red Team enabled:       %s\n' "$ENABLE_RED_TEAM"
  printf '\n%s\n' "$(color_text "$COLOR_BOLD" "Local tools")"
  for cmd in aws kubectl helm eksctl openssl python3 curl; do
    check_command "$cmd"
  done
  local tool_failures="$PREFLIGHT_FAILURES"

  printf '\n%s\n' "$(color_text "$COLOR_BOLD" "Secret inputs")"
  check_harbor_secret_input
  check_harbor_file_format
  check_secret_file "F5 license" "$F5_LICENSE_FILE" "F5_LICENSE_STRING"

  if [[ "$tool_failures" -gt 0 ]]; then
    printf '\n%s\n' "$(color_text "$COLOR_BOLD" "AWS access")"
    preflight_warn "Skipped because one or more required local tools are missing"
    printf '\n%s\n' "$(color_text "$COLOR_BOLD" "Deployment validation")"
    preflight_warn "Skipped because one or more required local tools are missing"
  else
    printf '\n%s\n' "$(color_text "$COLOR_BOLD" "AWS access")"
    check_aws_credentials
    check_aws_region
    check_route53_zone
    check_instance_offerings
    check_gpu_quota

    printf '\n%s\n' "$(color_text "$COLOR_BOLD" "Deployment validation")"
    check_eksctl_cluster_config
    check_harbor_login
    check_license_string
  fi

  if [[ "$PREFLIGHT_FAILURES" -gt 0 ]]; then
    printf '\n%s\n' "$(color_text "$COLOR_RED" "Preflight failed with $PREFLIGHT_FAILURES issue(s). Fix the items marked [FAIL], then rerun:")"
    printf '  ./scripts/guardrails-poc.sh preflight\n\n'
    exit 1
  fi

  if [[ "$mode" == "check" ]]; then
    printf '\n%s\n' "$(color_text "$COLOR_GREEN" "Preflight passed. The environment is ready to deploy.")"
    printf 'Start deployment with:\n'
    printf '  ./scripts/guardrails-poc.sh up\n\n'
  else
    printf '\n%s\n\n' "$(color_text "$COLOR_GREEN" "Preflight passed. Starting deployment.")"
  fi
}

cluster_exists() {
  aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1
}

addon_exists() {
  local addon="$1"
  aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name "$addon" --region "$AWS_REGION" >/dev/null 2>&1
}

nodegroup_exists() {
  local nodegroup="$1"
  aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$nodegroup" --region "$AWS_REGION" >/dev/null 2>&1
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
    run eksctl create cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --version "$K8S_VERSION" --managed --nodegroup-name "$GUARDRAIL_NODEGROUP_NAME" --node-type "$GUARDRAIL_NODE_TYPE" --nodes "$GUARDRAIL_NODE_COUNT" --nodes-min "$GUARDRAIL_NODE_MIN" --nodes-max "$GUARDRAIL_NODE_MAX" --node-volume-size "$GUARDRAIL_NODE_VOLUME_SIZE" --node-ami-family "$NODE_AMI_FAMILY" --install-nvidia-plugin --vpc-nat-mode "$VPC_NAT_MODE"
    if [[ "$ENABLE_RED_TEAM" == "true" ]]; then
      run eksctl create nodegroup --cluster "$CLUSTER_NAME" --region "$AWS_REGION" --name "$RED_TEAM_NODEGROUP_NAME" --node-type "$RED_TEAM_NODE_TYPE" --nodes "$RED_TEAM_NODE_COUNT" --nodes-min "$RED_TEAM_NODE_MIN" --nodes-max "$RED_TEAM_NODE_MAX" --node-volume-size "$RED_TEAM_NODE_VOLUME_SIZE" --node-ami-family "$NODE_AMI_FAMILY" --managed --install-nvidia-plugin
    fi
    return
  fi

  if cluster_exists; then
    log "EKS cluster already exists: $CLUSTER_NAME"
  else
    run eksctl create cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --version "$K8S_VERSION" --managed --nodegroup-name "$GUARDRAIL_NODEGROUP_NAME" --node-type "$GUARDRAIL_NODE_TYPE" --nodes "$GUARDRAIL_NODE_COUNT" --nodes-min "$GUARDRAIL_NODE_MIN" --nodes-max "$GUARDRAIL_NODE_MAX" --node-volume-size "$GUARDRAIL_NODE_VOLUME_SIZE" --node-ami-family "$NODE_AMI_FAMILY" --install-nvidia-plugin --vpc-nat-mode "$VPC_NAT_MODE"
  fi

  run aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"

  if [[ "$ENABLE_RED_TEAM" == "true" ]]; then
    if nodegroup_exists "$RED_TEAM_NODEGROUP_NAME"; then
      log "Red Team node group already exists: $RED_TEAM_NODEGROUP_NAME"
    else
      run eksctl create nodegroup --cluster "$CLUSTER_NAME" --region "$AWS_REGION" --name "$RED_TEAM_NODEGROUP_NAME" --node-type "$RED_TEAM_NODE_TYPE" --nodes "$RED_TEAM_NODE_COUNT" --nodes-min "$RED_TEAM_NODE_MIN" --nodes-max "$RED_TEAM_NODE_MAX" --node-volume-size "$RED_TEAM_NODE_VOLUME_SIZE" --node-ami-family "$NODE_AMI_FAMILY" --managed --install-nvidia-plugin
    fi
  fi
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
    local red_team_label="disabled"
    [[ "$ENABLE_RED_TEAM" == "true" ]] && red_team_label="enabled"
    printf '+ kubectl apply -f <SecurityOperator manifest for %s>\n' "$SECURITY_OPERATOR_NAME"
    printf '  SecurityOperator manifest: Guardrails enabled on %s, Red Team %s on %s, in-cluster PostgreSQL enabled, CAI_MODERATOR_BASE_URL=https://%s\n' "$GUARDRAIL_NODEGROUP_NAME" "$red_team_label" "$RED_TEAM_NODEGROUP_NAME" "$HOSTNAME"
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
  ENABLE_RED_TEAM="$ENABLE_RED_TEAM" \
  GUARDRAIL_NODEGROUP_NAME="$GUARDRAIL_NODEGROUP_NAME" \
  RED_TEAM_NODEGROUP_NAME="$RED_TEAM_NODEGROUP_NAME" \
  python3 - <<'PY'
import os
from pathlib import Path

redteam_enabled = os.environ["ENABLE_RED_TEAM"].lower()
redteam_profile = ""
if redteam_enabled == "true":
    redteam_profile = f"""          nvidia-gpu-l40s:
            nodeSelector:
              eks.amazonaws.com/nodegroup: {os.environ['RED_TEAM_NODEGROUP_NAME']}
"""

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
          enabled: {redteam_enabled}
      kubeai:
        resourceProfiles:
          nvidia-gpu-a10g:
            nodeSelector:
              eks.amazonaws.com/nodegroup: {os.environ['GUARDRAIL_NODEGROUP_NAME']}
{redteam_profile}
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

  if [[ "$DRY_RUN" == true ]]; then
    run helm upgrade --install "$INGRESS_RELEASE" "$INGRESS_CHART" --namespace "$INGRESS_NAMESPACE" --create-namespace --set-string 'controller.service.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-type=nlb' --set-string 'controller.service.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-scheme=internet-facing' --set controller.service.externalTrafficPolicy=Local
    run kubectl rollout status -n "$INGRESS_NAMESPACE" deploy/"$INGRESS_CONTROLLER_DEPLOYMENT" --timeout=300s
    return
  fi

  local attempt status
  for attempt in 1 2; do
    log "helm upgrade --install $INGRESS_RELEASE $INGRESS_CHART --namespace $INGRESS_NAMESPACE"
    if helm upgrade --install "$INGRESS_RELEASE" "$INGRESS_CHART" \
      --namespace "$INGRESS_NAMESPACE" \
      --create-namespace \
      --set-string 'controller.service.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-type=nlb' \
      --set-string 'controller.service.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-scheme=internet-facing' \
      --set controller.service.externalTrafficPolicy=Local; then
      break
    fi

    status="$(helm status "$INGRESS_RELEASE" -n "$INGRESS_NAMESPACE" -o json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("info", {}).get("status", "unknown"))' 2>/dev/null || printf 'not-found')"
    if [[ "$attempt" -eq 1 && "$status" == "failed" ]]; then
      log "Ingress controller Helm release is failed after install attempt; uninstalling failed release before retry"
      helm uninstall "$INGRESS_RELEASE" -n "$INGRESS_NAMESPACE" || true
      sleep 20
      continue
    fi

    die "Ingress controller Helm install failed; release status is $status"
  done

  run kubectl rollout status -n "$INGRESS_NAMESPACE" deploy/"$INGRESS_CONTROLLER_DEPLOYMENT" --timeout=300s
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
    nginx.org/proxy-read-timeout: "3600s"
    nginx.org/proxy-send-timeout: "3600s"
    nginx.org/ssl-redirect: "true"
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
  kubectl get svc -n "$INGRESS_NAMESPACE" "$INGRESS_CONTROLLER_SERVICE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
}

wait_for_ingress_lb() {
  if [[ "$DRY_RUN" == true ]]; then
    printf '+ wait for ingress controller load balancer hostname\n'
    return
  fi

  log "Waiting for ingress controller load balancer hostname"
  local lb=""
  for _ in {1..60}; do
    lb="$(get_ingress_lb || true)"
    if [[ -n "$lb" ]]; then
      printf '%s\n' "$lb"
      return
    fi
    sleep 10
  done
  die "Timed out waiting for ingress controller load balancer hostname"
}

route53_upsert() {
  local lb="$1"
  if [[ "$ROUTE53_ENABLED" != "true" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      printf '+ skip Route 53 UPSERT for %s because ROUTE53_ENABLED=false\n' "$HOSTNAME"
    else
      log "Route 53 management disabled; skipping DNS upsert for $HOSTNAME"
    fi
    return
  fi

  if [[ "$DRY_RUN" == true ]]; then
    printf '+ route53 UPSERT %s -> <ingress-load-balancer>\n' "$HOSTNAME"
    return
  fi

  local zone_id change_file
  zone_id="$(resolve_hosted_zone_id)"
  [[ -n "$zone_id" && "$zone_id" != "None" ]] || die "Could not resolve Route 53 hosted zone for $ROUTE53_ZONE_NAME"
  change_file="$(mktemp)"
  HOSTNAME="$HOSTNAME" LB_HOSTNAME="$lb" python3 - "$change_file" <<'PY'
import json, os, sys
change = {
    "Comment": "Point Guardrails PoC hostname to ingress load balancer",
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
  if [[ "$ROUTE53_ENABLED" != "true" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      printf '+ skip Route 53 DELETE for %s because ROUTE53_ENABLED=false\n' "$HOSTNAME"
    else
      log "Route 53 management disabled; skipping DNS delete for $HOSTNAME"
    fi
    return
  fi

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

status_line() {
  printf '%-26s %s\n' "$1:" "$(color_status_value "$2")"
}

get_dns_record() {
  if [[ "$ROUTE53_ENABLED" != "true" ]]; then
    printf 'disabled'
    return
  fi

  local zone_id
  zone_id="$(resolve_hosted_zone_id)"
  if [[ -z "$zone_id" || "$zone_id" == "None" ]]; then
    printf 'unknown'
    return
  fi

  aws route53 list-resource-record-sets \
    --hosted-zone-id "$zone_id" \
    --query "ResourceRecordSets[?Name=='${HOSTNAME}.' && Type=='CNAME'] | [0].ResourceRecords[0].Value" \
    --output text 2>/dev/null || true
}

print_dns_status() {
  local current
  current="$(get_dns_record)"
  if [[ -z "$current" || "$current" == "None" ]]; then
    status_line "DNS record" "deleted ($HOSTNAME not present)"
  elif [[ "$current" == "disabled" ]]; then
    status_line "DNS record" "disabled (Route 53 not managed by script)"
  elif [[ "$current" == "unknown" ]]; then
    status_line "DNS record" "unknown (hosted zone $ROUTE53_ZONE_NAME not found)"
  else
    status_line "DNS record" "present ($HOSTNAME -> $current)"
  fi
}

get_leftover_volumes() {
  aws ec2 describe-volumes \
    --region "$AWS_REGION" \
    --filters "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned" "Name=status,Values=available" \
    --query 'Volumes[].[VolumeId,State,Size,Tags[?Key==`Name`].Value|[0]]' \
    --output text 2>/dev/null || true
}

print_leftover_volume_status() {
  local volumes
  volumes="$(get_leftover_volumes)"
  if [[ -z "$volumes" || "$volumes" == "None" ]]; then
    status_line "EBS volumes" "none found with cluster-owned tag"
  else
    status_line "EBS volumes" "leftovers found"
    printf '%s\n' "$volumes" | sed 's/^/  /'
  fi
}

pod_health() {
  local namespace="$1"
  local rows ready total
  rows="$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null || true)"
  if [[ -z "$rows" ]]; then
    printf 'not found'
    return
  fi

  read -r ready total <<< "$(printf '%s\n' "$rows" | awk '
    NF {
      total++
      split($2, containers, "/")
      if ($3 == "Completed" || $3 == "Succeeded" || (containers[1] == containers[2] && $3 == "Running")) {
        ready++
      }
    }
    END { printf "%d %d", ready + 0, total + 0 }
  ')"

  if [[ "$total" -gt 0 && "$ready" -eq "$total" ]]; then
    printf 'ready (%s/%s pods)' "$ready" "$total"
  else
    printf 'warning (%s/%s pods ready)' "$ready" "$total"
  fi
}

deployment_health() {
  local namespace="$1"
  local deployment="$2"
  local replicas ready
  replicas="$(kubectl get deploy "$deployment" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
  ready="$(kubectl get deploy "$deployment" -n "$namespace" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  replicas="${replicas:-0}"
  ready="${ready:-0}"

  if [[ "$replicas" -gt 0 && "$ready" -eq "$replicas" ]]; then
    printf 'ready (%s/%s replicas)' "$ready" "$replicas"
  elif [[ "$replicas" -eq 0 ]]; then
    printf 'not found'
  else
    printf 'warning (%s/%s replicas ready)' "$ready" "$replicas"
  fi
}

storage_health() {
  local addon_status default_class
  addon_status="$(aws eks describe-addon \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name aws-ebs-csi-driver \
    --region "$AWS_REGION" \
    --query 'addon.status' \
    --output text 2>/dev/null || true)"
  default_class="$(kubectl get storageclass "$POSTGRES_STORAGE_CLASS" -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null || true)"

  if [[ "$addon_status" == "ACTIVE" && "$default_class" == "true" ]]; then
    printf 'ready (EBS CSI active, %s default)' "$POSTGRES_STORAGE_CLASS"
  elif [[ "$addon_status" == "ACTIVE" ]]; then
    printf 'warning (EBS CSI active, %s not default)' "$POSTGRES_STORAGE_CLASS"
  else
    printf 'warning (EBS CSI add-on %s)' "${addon_status:-not found}"
  fi
}

node_health() {
  local rows ready total node_type
  rows="$(kubectl get nodes --no-headers 2>/dev/null || true)"
  if [[ -z "$rows" ]]; then
    printf 'not found'
    return
  fi

  read -r ready total <<< "$(printf '%s\n' "$rows" | awk '
    NF {
      total++
      if ($2 == "Ready") {
        ready++
      }
    }
    END { printf "%d %d", ready + 0, total + 0 }
  ')"
  node_type="$(kubectl get nodes -o jsonpath='{.items[0].metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null || true)"

  if [[ "$ready" -eq "$total" ]]; then
    printf '%s/%s Ready, type %s' "$ready" "$total" "${node_type:-unknown}"
  else
    printf 'warning (%s/%s Ready), type %s' "$ready" "$total" "${node_type:-unknown}"
  fi
}

nodegroup_health() {
  local nodegroup="$1"
  local status desired min max instance_type
  status="$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$nodegroup" --region "$AWS_REGION" --query 'nodegroup.status' --output text 2>/dev/null || true)"
  if [[ -z "$status" || "$status" == "None" ]]; then
    printf 'not found'
    return
  fi
  desired="$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$nodegroup" --region "$AWS_REGION" --query 'nodegroup.scalingConfig.desiredSize' --output text 2>/dev/null || true)"
  min="$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$nodegroup" --region "$AWS_REGION" --query 'nodegroup.scalingConfig.minSize' --output text 2>/dev/null || true)"
  max="$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$nodegroup" --region "$AWS_REGION" --query 'nodegroup.scalingConfig.maxSize' --output text 2>/dev/null || true)"
  instance_type="$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$nodegroup" --region "$AWS_REGION" --query 'nodegroup.instanceTypes[0]' --output text 2>/dev/null || true)"
  printf '%s, %s desired (%s-%s), type %s' "$status" "${desired:-unknown}" "${min:-?}" "${max:-?}" "${instance_type:-unknown}"
}

public_url_health() {
  if [[ "$ROUTE53_ENABLED" != "true" ]]; then
    printf 'not verified (DNS not managed by script)'
    return
  fi

  if curl -k -fsSI --max-time 5 "https://$HOSTNAME/" >/dev/null 2>&1; then
    printf 'online (https://%s)' "$HOSTNAME"
  else
    printf 'not reachable yet (https://%s)' "$HOSTNAME"
  fi
}

print_troubleshooting_hints() {
  printf '\n%s\n' "$(color_text "$COLOR_BOLD" "Troubleshooting")"
  printf '  Detailed pods:      kubectl get pods -A\n'
  printf '  Ingress details:    kubectl get ingress,svc -n %s\n' "$MODERATOR_NAMESPACE"
  printf '  App logs:           kubectl logs -n %s deploy/cai-moderator --tail=100\n' "$MODERATOR_NAMESPACE"
  printf '  Script preflight:   ./scripts/guardrails-poc.sh preflight\n'
}

print_access_info() {
  local realm
  print_heading "Access" "======"
  status_line "UI" "https://$HOSTNAME"
  status_line "Initial username" "$GUARDRAILS_DEFAULT_USERNAME"
  status_line "Initial password" "$GUARDRAILS_DEFAULT_PASSWORD (until changed)"
  printf 'Password change:\n'
  for realm in $GUARDRAILS_AUTH_REALMS; do
    printf '  Realm %-12s https://%s/auth/realms/%s/account/#/security/signingin\n' "$realm" "$HOSTNAME" "$realm"
  done
  printf 'Note: Keycloak passwords are realm-specific. If more than one realm accepts the initial password, change it in each realm.\n'
}

status_stopped() {
  print_heading "Guardrails PoC status" "====================="
  status_line "Environment" "stopped"
  status_line "EKS cluster" "not found ($CLUSTER_NAME in $AWS_REGION)"
  print_dns_status
  print_leftover_volume_status
  status_line "Kubernetes" "skipped because the EKS cluster is deleted"
  status_line "Public URL" "offline (https://$HOSTNAME)"
  print_access_info
  printf '\nNext actions:\n'
  printf '  Start again:        ./scripts/guardrails-poc.sh up\n'
  printf '  Re-check status:    ./scripts/guardrails-poc.sh status\n'
}

verify_public_url() {
  if [[ "$ROUTE53_ENABLED" != "true" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      printf '+ skip public URL verification because ROUTE53_ENABLED=false\n'
    else
      log "Route 53 management disabled; skipping public URL verification for https://$HOSTNAME"
    fi
    return
  fi

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
  preflight_up deploy
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

do_preflight() {
  preflight_up check
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

  local cluster_status cluster_version dns_record ingress_lb leftovers public_status
  cluster_status="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.status' --output text 2>/dev/null || true)"
  cluster_version="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.version' --output text 2>/dev/null || true)"
  dns_record="$(get_dns_record)"
  ingress_lb="$(get_ingress_lb 2>/dev/null || true)"
  leftovers="$(get_leftover_volumes)"
  public_status="$(public_url_health)"

  print_heading "Guardrails PoC status" "====================="
  status_line "Environment" "running"
  status_line "Public URL" "$public_status"
  if [[ -z "$dns_record" || "$dns_record" == "None" ]]; then
    status_line "DNS" "missing ($HOSTNAME)"
  elif [[ "$dns_record" == "disabled" ]]; then
    status_line "DNS" "disabled (set ROUTE53_ENABLED=true to manage Route 53)"
  elif [[ "$dns_record" == "unknown" ]]; then
    status_line "DNS" "unknown (hosted zone $ROUTE53_ZONE_NAME not found)"
  else
    status_line "DNS" "present -> $dns_record"
  fi
  if [[ -n "$ingress_lb" ]]; then
    status_line "Ingress LB" "ready -> $ingress_lb"
  else
    status_line "Ingress LB" "pending"
  fi
  status_line "EKS cluster" "${cluster_status:-unknown}, Kubernetes ${cluster_version:-unknown}, region $AWS_REGION"
  status_line "Node" "$(node_health)"
  status_line "Guardrails node group" "$(nodegroup_health "$GUARDRAIL_NODEGROUP_NAME")"
  if [[ "$ENABLE_RED_TEAM" == "true" ]]; then
    status_line "Red Team node group" "$(nodegroup_health "$RED_TEAM_NODEGROUP_NAME")"
  fi
  status_line "Storage" "$(storage_health)"
  status_line "f5-ai-security-operator" "$(deployment_health "$F5_NAMESPACE" controller-manager)"
  status_line "cai-moderator" "$(pod_health "$MODERATOR_NAMESPACE")"
  status_line "f5-ai-sec-inference" "$(pod_health "$INFERENCE_NAMESPACE")"
  if [[ "$ENABLE_RED_TEAM" == "true" ]]; then
    status_line "Red Team" "enabled"
  else
    status_line "Red Team" "disabled"
  fi
  status_line "prefect" "$(pod_health "$PREFECT_NAMESPACE")"
  status_line "$INGRESS_NAMESPACE" "$(deployment_health "$INGRESS_NAMESPACE" "$INGRESS_CONTROLLER_DEPLOYMENT")"
  if [[ -z "$leftovers" || "$leftovers" == "None" ]]; then
    status_line "EBS leftovers" "none found"
  else
    status_line "EBS leftovers" "warning (cluster-tagged volumes found)"
  fi

  print_access_info

  printf '\nNext actions:\n'
  if [[ "$public_status" == online* ]]; then
    printf '  Open UI:           https://%s\n' "$HOSTNAME"
  else
    printf '  Complete deploy:   ./scripts/guardrails-poc.sh up\n'
  fi
  printf '  Stop PoC:          ./scripts/guardrails-poc.sh down --yes\n'
  printf '  Re-check status:   ./scripts/guardrails-poc.sh status\n'

  if [[ -z "$ingress_lb" || -z "$dns_record" || "$dns_record" == "None" || "$dns_record" == "unknown" || -n "$leftovers" && "$leftovers" != "None" ]]; then
    print_troubleshooting_hints
  fi
}

load_config
init_colors

case "$ACTION" in
  preflight) do_preflight ;;
  up) do_up ;;
  down) do_down ;;
  status) require_tools; status ;;
  *) die "Unknown action: $ACTION" ;;
esac
