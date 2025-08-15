# Install the Kubernetes dashboard
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml
# Create the Kubernetes user toke
kubectl -n kubernetes-dashboard create token admin-user

# Install Capacitor
kubectl apply -f kubernetes/dashboards/capacitor.yaml
# Expose capacitor service
kubectl -n flux-system port-forward svc/capacitor 9000

# Delete pipeline runs to free resources
tkn pipelinerun list -n infra --no-headers=true | awk '/node-helm-run/{print $1}' | xargs tkn pipelinerun -n infra delete --force
tkn pipelinerun list -n infra --no-headers=true | awk '/maven-helm-run/{print $1}' | xargs tkn pipelinerun -n infra delete --force
tkn pipelinerun list -n infra --no-headers=true | awk '/maven-lib-run/{print $1}' | xargs tkn pipelinerun -n infra delete --force

# Remove all containers
docker rm -f $(docker ps -a -q)
# Remove all images
docker rmi -f $(docker images -a -q)
# Remove all resources (unused containers, volumes, and networks in addition to images)
docker system prune -a -f

# Get Tekton pipeline services
kubectl get svc -n tekton-pipelines

# Docker login on ghcr.io. This assumes a GitHub Personal Access Token with necessary rights is
# contained within the GITHUB_PERSONAL_ACCESS_TOKEN environment variable.
echo $GITHUB_PERSONAL_ACCESS_TOKEN | docker login ghcr.io -u <GITHUB_USERNAME> --password-stdin