# Table of Contents
1. [On-premises deployment](#on-premises-deployment)
	1. [Setting up Wireguard on both on the cloud virtual machine and on the on-premises machine](#wireguard-vpn).
	2. [Setting up Nginx on the cloud virtual machine](#nginx-on-the-cloud-virtual-machine).
	3. [Adding host entries on the on-premises machine](#on-premises-host-entries).
	4. [Setting up a kubernetes cluster on the on-premises machine](#kubernetes-on-premises).
2. [Artifactory](#artifactory)
3. [Pipelines](#pipelines)
4. [Kubernetes Dashboard](#kubernetes-dashboard)
5. [FluxCD UI](#fluxcd-ui)
6. [Deleting pipeline runs](#deleting-pipeline-runs)
7. [Removing unused Docker resources](#removing-unused-docker-resources)
8. [Logging in to GitHub Container Registry](#logging-in-to-github-container-registry)
## On-premises deployment
Deploying on-premises requires setting up a Wireguard VPN, setting up a reverse proxy, adding host entries, and setting up a Kubernetes cluster as describe in each of the below subsections.
### Wireguard VPN
Set up a Wireguard VPN. There is a good procedure on https://docs.vultr.com/how-to-install-wireguard-vpn-on-debian-12.
### Nginx on the cloud virtual machine
Install nginx on the cloud virtual machine. An example configuration file is given in on-premises/nginx/nguiland.org. Note how traffic to port 80 (http) is redirected to port 443 (https) in the example file. Also note that in the example file, 10.0.0.2 is assumed to be the Wireguard client IP address.
### On-premises host entries
On the on-premises machine, the below entries should be added to the /etc/hosts file:
```
127.0.0.1 artifactory-jcr.infra
127.0.0.1 keycloak.infra
127.0.0.1 artifactory-oss.infra
127.0.0.1 angular-frontend.ostock
127.0.0.1 gateway-service.ostock
```
### Kubernetes on-premises
1. Clone the git@github.com:biya-bi/nguiland-infra-engine.git repository on the on-premises machine.
2. At the root of the directory that was just cloned, run `./bootstrap.sh int <branch_name>`, replacing `<branch_name>` with the actual branch name. Note that we have specified the **int** cluster in the later command. Deployment on-premises require that the cluster name in the command be **int**.
3. After running `./bootstrap.sh int <branch_name>` on the server, do the following:
	1. Use kubectl to expose services. The Wireguard client IP address should be used in port forwarding. For example, `kubectl port-forward svc/artifactory-jcr 9001:8082 -n infra --address=10.0.0.2`
	2. Test artifactory-jcr and artifactory-oss port forwarding using the curl command. If the port forwarding loses connection to the pod after running the curl, restart the pods using a command similar to `kubectl rollout restart deployment <deployment_name> -n infra`, then test the curl again. If the curl now succeeds, stop kubectl port forwarding command for the given service and run step 1 again for the service in question.
## Artifactory
Independent of the environment, once artifactory-jcr and artifactory-oss deployments are successful, the next step should be to login and change the default passwords to those encrypted by SOPS-AGE and deployed to the cluster. If this is not done, deployments that use secrets deployed in the cluster will fail. For example, pipeline runs will push Docker images to JFrog Container Registry (artifactory-jcr) using secrets deployed in the cluster. This clearly means that the default password of admin user for artifactory-jcr should be changed to that deployed in the cluster for the image push to be successful.
## Pipelines
The pipeline directory contains manifests that can be used to manually launch pipelines. This can be done using commands of the form `kubectl apply -f <manifest_path>`. Note that most pipeline runs have an environment parameter which may have to be changed (or commented out) to match on the environment on which the deployment is made.
Ideally the pipelines should be run in the below order:
```
kubectl create -f kubernetes/pipelines/infra/maven/lib-parent.yaml
kubectl create -f kubernetes/pipelines/infra/maven/io-utils.yaml
kubectl create -f kubernetes/pipelines/ostock/maven/dto.yaml
kubectl create -f kubernetes/pipelines/ostock/maven/orm.yaml
kubectl create -f kubernetes/pipelines/ostock/maven/cross-cutting-concerns.yaml
kubectl create -f kubernetes/pipelines/ostock/maven/config-service.yaml
kubectl create -f kubernetes/pipelines/ostock/maven/eureka-service.yaml
kubectl create -f kubernetes/pipelines/ostock/maven/gateway-service.yaml
kubectl create -f kubernetes/pipelines/ostock/maven/licensing-service.yaml
kubectl create -f kubernetes/pipelines/ostock/maven/organization-service.yaml
kubectl create -f kubernetes/pipelines/ostock/node/angular-frontend.yaml
```
Pipelinerun logs can be viewed using the below command:
```
tkn pipelinerun logs -n infra -f
```
## Kubernetes Dashboard
If a Kubernetes Dashboard is required, the below commands may be useful: 
```
# Install the Kubernetes Dashboard
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml
# Create the Kubernetes admin user
kubectl apply -f kubernetes/dashboards/kubernetes-dashboard-admin-user.yaml
# Create the Kubernetes admin user token
kubectl -n kubernetes-dashboard create token admin-user
# Expose the kubernetes-dashboard service
kubectl -n kubernetes-dashboard port-forward svc/kubernetes-dashboard 8443:443
```
## FluxCD UI
If a FluxCD UI is required, Capacitor can be considered. The below command may be useful:
```
# Install Capacitor
kubectl apply -f kubernetes/dashboards/capacitor.yaml
# Expose the capacitor service
kubectl -n flux-system port-forward svc/capacitor 9000
```
## Deleting pipeline runs
The below commands can be used in deleting pipeline runs:
```
# Delete non-running pipeline runs
tkn pipelinerun ls  -n infra --no-headers=true | awk -v STATUS="Running" '$NF != STATUS {print}' | awk '{print $1}' | xargs tkn pipelinerun -n infra delete --force
# Delete each node-helm pipeline run whose name starts with node-helm-run
tkn pipelinerun list -n infra --no-headers=true | awk '/node-helm-run/{print $1}' | xargs tkn pipelinerun -n infra delete --force
# Delete each node-helm pipeline run whose name starts with maven-helm-run
tkn pipelinerun list -n infra --no-headers=true | awk '/maven-helm-run/{print $1}' | xargs tkn pipelinerun -n infra delete --force
# Delete each node-helm pipeline run whose name starts with maven-lib-run
tkn pipelinerun list -n infra --no-headers=true | awk '/maven-lib-run/{print $1}' | xargs tkn pipelinerun -n infra delete --force
```
## Removing unused Docker resources
The below commands may be used to remove used Docker resources. As is the case with any clean up activities, prune should be used with extreme care. In fact, it should ideally be used on development environments. For example, prune may delete a database volume if it is not currently attached to a running container.
```
# Remove all containers
docker rm -f $(docker ps -a -q)
# Remove all images
docker rmi -f $(docker images -a -q)
# Remove all resources (unused containers, volumes, and networks in addition to images)
docker system prune -a -f
```
## Tekton
The below commands may be helpful in working with Tekton
```
# Get Tekton pipeline services
kubectl get svc -n tekton-pipelines
```
## Logging in to GitHub Container Registry
```
# This assumes a GitHub Personal Access Token with necessary rights is contained within the GITHUB_PERSONAL_ACCESS_TOKEN environment variable.
echo $GITHUB_PERSONAL_ACCESS_TOKEN | docker login ghcr.io -u <GITHUB_USERNAME> --password-stdin
```
