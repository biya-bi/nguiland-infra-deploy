# Table of Contents
1. [On-premises deployment](#on-premises-deployment)
	1. [Setting up Wireguard on both on the cloud virtual machine and on the on-premises machine](#wireguard-vpn).
	2. [Setting up Nginx on the cloud virtual machine](#nginx-on-the-cloud-virtual-machine).
	3. [Adding host entries on the on-premises machine](#on-premises-host-entries).
	4. [Setting up a kubernetes cluster on the on-premises machine](#kubernetes-on-premises).
2. [Artifactory](#artifactory)
3. [Commands](#commands)
4. [Pipelines](#pipelines)
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
2. At the root of the directory that was just cloned, run `./bootstrap.sh local <branch_name>`, replacing `<branch_name>` with the actual branch name. Note that we have specified the **local** cluster in the later command. Deployment on-premises require that the cluster name in the command be **local**.
3. After running `./bootstrap.sh local <branch_name>` on the server, do the following:
	1. Use kubectl to expose services. The Wireguard client IP address should be used in port forwarding. For example, `kubectl port-forward svc/artifactory-jcr 9001:8082 -n infra --address=10.0.0.2`
	2. Test artifactory-jcr and artifactory-oss port forwarding using the curl command. If the port forwarding loses connection to the pod after running the curl, restart the pods using a command similar to `kubectl rollout restart deployment <deployment_name> -n infra`, then test the curl again. If the curl now succeeds, stop kubectl port forwarding command for the given service and run step 1 again for the service in question.
## Artifactory
Independent of the environment, once artifactory-jcr and artifactory-oss deployments are successful, the next step should be to login and change the default passwords to those encrypted by SOPS-AGE and deployed to the cluster. If this is not done, deployments that use secrets deployed in the cluster will fail. For example, pipeline runs will push Docker images to JFrog Container Registry (artifactory-jcr) using secrets deployed in the cluster. This clearly means that the default password of admin user for artifactory-jcr should be changed to that deployed in the cluster for the image push to be successful.
## Commands
Some helpful commands are given in the commands.sh file.
## Pipelines
The pipeline directory contains manifest that can be used to manually launch pipelines. This can be done using commands of the form `kubectl apply -f <manifest_path>`. Note that most pipeline runs have an environment parameter which may have to be changed (or commented out) to match on the environment on which the deployment is made.
Ideally the first pipeline runs should be in the below order:
```
kubectl apply -f kubernetes/pipelines/infra/maven/lib-parent.yaml
kubectl apply -f kubernetes/pipelines/infra/maven/io-utils.yaml
kubectl apply -f kubernetes/pipelines/ostock/maven/dto.yaml
kubectl apply -f kubernetes/pipelines/ostock/maven/orm.yaml
kubectl apply -f kubernetes/pipelines/ostock/maven/cross-cutting-concerns.yaml
kubectl apply -f kubernetes/pipelines/ostock/maven/config-service.yaml
kubectl apply -f kubernetes/pipelines/ostock/maven/eureka-service.yaml
kubectl apply -f kubernetes/pipelines/ostock/maven/gateway-service.yaml
kubectl apply -f kubernetes/pipelines/ostock/maven/licensing-service.yaml
kubectl apply -f kubernetes/pipelines/ostock/maven/organization-service.yaml
kubectl apply -f kubernetes/pipelines/ostock/node/angular-frontend.yaml
```
