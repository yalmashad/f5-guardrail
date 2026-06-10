#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/guardrails-poc.sh"

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "Expected output to contain: $needle" >&2
    exit 1
  fi
}

run_dry() {
  "$SCRIPT" --config "$ROOT_DIR/config/guardrails-poc.env.example" --dry-run "$@"
}

up_output="$(run_dry up)"
assert_contains "$up_output" "eksctl create cluster"
assert_contains "$up_output" "--install-nvidia-plugin"
assert_contains "$up_output" "eksctl create addon --cluster f5-guardrails-poc --region us-east-1 --name eks-pod-identity-agent"
assert_contains "$up_output" "eksctl create addon --cluster f5-guardrails-poc --region us-east-1 --name aws-ebs-csi-driver"
assert_contains "$up_output" "kubectl patch storageclass gp2"
assert_contains "$up_output" "helm upgrade --install f5-ai-security-operator"
assert_contains "$up_output" "SecurityOperator manifest"
assert_contains "$up_output" "helm upgrade --install ingress-nginx"
assert_contains "$up_output" "cai-moderator-ingress"
assert_contains "$up_output" "route53 UPSERT guardrails.f5demo.io"
assert_contains "$up_output" "cai-workflows-manual"

down_output="$(run_dry down --yes)"
assert_contains "$down_output" "route53 DELETE guardrails.f5demo.io"
assert_contains "$down_output" "eksctl delete cluster --name f5-guardrails-poc --region us-east-1 --wait"
assert_contains "$down_output" "find available EBS volumes tagged kubernetes.io/cluster/f5-guardrails-poc=owned"
assert_contains "$down_output" "aws ec2 delete-volume --region us-east-1 --volume-id <leftover-pvc-volume>"

status_output="$(run_dry status)"
assert_contains "$status_output" "aws eks describe-cluster --name f5-guardrails-poc --region us-east-1"
assert_contains "$status_output" "kubectl get pods -n cai-moderator -o wide"

echo "guardrails-poc dry-run tests passed"
