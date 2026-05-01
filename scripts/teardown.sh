#!/usr/bin/env bash

echo "--- 1. STOPPING THE FLUX GITOPS SYSTEM ---"
flux uninstall --namespace flux-system --silent 2>/dev/null
flux uninstall --namespace infra --silent 2>/dev/null
flux uninstall --namespace kyverno --silent 2>/dev/null
flux uninstall --namespace tekton-pipelines --silent 2>/dev/null

echo "--- 2. KILLING CONTROLLER LOOPS (Scaling) ---"
# Stop everything that could recreate webhooks or block deletions
kubectl scale deployment --all --replicas=0 -A 2>/dev/null
kubectl scale statefulset --all --replicas=0 -A 2>/dev/null
kubectl scale daemonset --all --replicas=0 -A 2>/dev/null

# Give the API a moment to register the shutdown
sleep 2

echo "--- 3. DISABLING CRD WEBHOOKS ---"
# This stops the "connection refused" errors by telling the API server
# to stop trying to use Kyverno's service to process its CRDs.
kubectl get crds -o name | grep 'kyverno.io' | xargs -I {} kubectl patch {} --type='json' -p='[{"op": "replace", "path": "/spec/conversion/strategy", "value": "None"}]' 2>/dev/null

echo "--- 4. PURGING ADMISSION GATEKEEPERS (Webhooks) ---"
kubectl delete validatingwebhookconfigurations --all --force --grace-period=0 2>/dev/null
kubectl delete mutatingwebhookconfigurations --all --force --grace-period=0 2>/dev/null

echo "--- 5. NUKING DEFINITIONS AND NAMESPACES ---"
# Delete CRDs now that their conversion webhooks are disabled
kubectl get crds -o name | xargs -I {} kubectl delete {} --timeout=10s 2>/dev/null

# Trigger namespace deletion
kubectl delete ns kyverno tekton-pipelines tekton-dashboard tekton-pipelines-resolvers infra --ignore-not-found --wait=false

echo "--- 6. FINALIZER CLEANUP (The Final Kill) ---"
for ns in kyverno tekton-pipelines tekton-dashboard tekton-pipelines-resolvers infra flux-system; do
  kubectl patch ns "$ns" -p '{"spec":{"finalizers":[]}}' --type=merge 2>/dev/null
done

echo "--- RESET COMPLETE ---"
