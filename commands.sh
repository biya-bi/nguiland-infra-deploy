# Get Tekton pipeline services
kubectl get svc -n tekton-pipelines

# Docker login on ghcr.io. This assumes a GitHub Personal Access Token with necessary rights is
# contained within the GITHUB_PERSONAL_ACCESS_TOKEN environment variable.
echo $GITHUB_PERSONAL_ACCESS_TOKEN | docker login ghcr.io -u <GITHUB_USERNAME> --password-stdin