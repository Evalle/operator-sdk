#!/usr/bin/env bash

source hack/lib/test_lib.sh

DEST_IMAGE="quay.io/example/nginx-operator:v0.0.2"

set -ex

# if on openshift switch to the "default" namespace
# and allow containers to run as root (necessary for
# default nginx image)
if which oc 2>/dev/null;
then
    oc project default
    oc adm policy add-scc-to-user anyuid -z default
fi

# Make a test directory for Helm tests so we avoid using default GOPATH.
# Save test directory so we can delete it on exit.
HELM_TEST_DIR="$(mktemp -d)"
trap_add 'rm -rf $HELM_TEST_DIR' EXIT
cp -a test/helm-* "$HELM_TEST_DIR"
pushd "$HELM_TEST_DIR"

# Helm tests should not run in a Golang environment.
unset GOPATH GOROOT

# create and build the operator
operator-sdk new nginx-operator --api-version=helm.example.com/v1alpha1 --kind=Nginx --type=helm
pushd nginx-operator
sed -i 's|\(FROM quay.io/operator-framework/helm-operator\)\(:.*\)\?|\1:dev|g' build/Dockerfile

operator-sdk build "$DEST_IMAGE"
sed -i "s|REPLACE_IMAGE|$DEST_IMAGE|g" deploy/operator.yaml
sed -i 's|Always|Never|g' deploy/operator.yaml
sed -i 's|size: 3|replicaCount: 1|g' deploy/crds/helm_v1alpha1_nginx_cr.yaml

DIR2="$(pwd)"
# deploy the operator
kubectl create -f deploy/service_account.yaml
trap_add 'kubectl delete -f ${DIR2}/deploy/service_account.yaml' EXIT
kubectl create -f deploy/role.yaml
trap_add 'kubectl delete -f ${DIR2}/deploy/role.yaml' EXIT
kubectl create -f deploy/role_binding.yaml
trap_add 'kubectl delete -f ${DIR2}/deploy/role_binding.yaml' EXIT
kubectl create -f deploy/crds/helm_v1alpha1_nginx_crd.yaml
trap_add 'kubectl delete -f ${DIR2}/deploy/crds/helm_v1alpha1_nginx_crd.yaml' EXIT
kubectl create -f deploy/operator.yaml
trap_add 'kubectl delete -f ${DIR2}/deploy/operator.yaml' EXIT

# wait for operator pod to run
if ! timeout 1m kubectl rollout status deployment/nginx-operator;
then
    kubectl logs deployment/nginx-operator
    exit 1
fi

# create CR
kubectl create -f deploy/crds/helm_v1alpha1_nginx_cr.yaml
trap_add 'kubectl delete --ignore-not-found -f ${DIR2}/deploy/crds/helm_v1alpha1_nginx_cr.yaml' EXIT
if ! timeout 1m bash -c -- 'until kubectl get nginxes.helm.example.com example-nginx -o jsonpath="{..status.conditions[1].release.info.status.code}" | grep 1; do sleep 1; done';
then
    kubectl logs deployment/nginx-operator
    exit 1
fi

release_name=$(kubectl get nginxes.helm.example.com example-nginx -o jsonpath="{..status.conditions[1].release.name}")
nginx_deployment=$(kubectl get deployment -l "app.kubernetes.io/instance=${release_name}" -o jsonpath="{..metadata.name}")

if ! timeout 1m kubectl rollout status deployment/${nginx_deployment};
then
    kubectl describe pods -l "app.kubernetes.io/instance=${release_name}"
    kubectl describe deployments ${nginx_deployment}
    kubectl logs deployment/${nginx_deployment}
    exit 1
fi

nginx_service=$(kubectl get service -l "app.kubernetes.io/instance=${release_name}" -o jsonpath="{..metadata.name}")
kubectl get service ${nginx_service}

# scale deployment replicas to 2 and verify the
# deployment automatically scales back down to 1.
kubectl scale deployment/${nginx_deployment} --replicas=2
if ! timeout 1m test $(kubectl get deployment/${nginx_deployment} -o jsonpath="{..spec.replicas}") -eq 1;
then
    kubectl describe pods -l "app.kubernetes.io/instance=${release_name}"
    kubectl describe deployments ${nginx_deployment}
    kubectl logs deployment/${nginx_deployment}
    exit 1
fi

# update CR to replicaCount=2 and verify the deployment
# automatically scales up to 2 replicas.
kubectl patch nginxes.helm.example.com example-nginx -p '[{"op":"replace","path":"/spec/replicaCount","value":2}]' --type=json
if ! timeout 1m test $(kubectl get deployment/${nginx_deployment} -o jsonpath="{..spec.replicas}") -eq 2;
then
    kubectl describe pods -l "app.kubernetes.io/instance=${release_name}"
    kubectl describe deployments ${nginx_deployment}
    kubectl logs deployment/${nginx_deployment}
    exit 1
fi

kubectl delete -f deploy/crds/helm_v1alpha1_nginx_cr.yaml --wait=true
kubectl logs deployment/nginx-operator | grep "Uninstalled release" | grep "${release_name}"

popd
popd
