#!/bin/bash
#set -x

#View build properties
cat build.properties

#Check cluster availability
ip_addr=$(bx cs workers $PIPELINE_KUBERNETES_CLUSTER_NAME | grep normal | awk '{ print $2 }')
if [ -z $ip_addr ]; then
  echo "$PIPELINE_KUBERNETES_CLUSTER_NAME not created or workers not ready"
  exit 1
fi

#Check cluster target namespace 
if ! kubectl get namespace $CLUSTER_NAMESPACE; then
  kubectl create namespace $CLUSTER_NAMESPACE
fi

# Grant access to private image registry from namespace $CLUSTER_NAMESPACE
if ! kubectl get secret bluemix-devops-secret --namespace $CLUSTER_NAMESPACE; then
  # copy the existing default secret into the new namespace
  kubectl get secret bluemix-default-secret -o yaml |  sed "s~^\([[:blank:]]*\)namespace:.*$~\1namespace: ${CLUSTER_NAMESPACE}~" | kubectl -n $CLUSTER_NAMESPACE create -f -
  # enable default serviceaccount to use the pull secret
  kubectl patch -n $CLUSTER_NAMESPACE serviceaccount/default -p '{"imagePullSecrets":[{"name":"bluemix-default-secret"}]}'
  echo "Namespace $CLUSTER_NAMESPACE is now authorized to pull from the private image registry"
fi

# Grant access to private image registry from namespace $CLUSTER_NAMESPACE
echo "create ${IMAGE_PULL_SECRET_NAME} imagePullSecret if it does not exist"
if ! kubectl get secret ${IMAGE_PULL_SECRET_NAME} --namespace $CLUSTER_NAMESPACE; then
  echo "${IMAGE_PULL_SECRET_NAME} not found in $CLUSTER_NAMESPACE, creating it"
  # for Container Registry, docker username is 'token' and email does not matter
  kubectl --namespace $CLUSTER_NAMESPACE create secret docker-registry $IMAGE_PULL_SECRET_NAME --docker-server=$REGISTRY_HOST --docker-password=$IMAGE_REGISTRY_TOKEN --docker-username=token --docker-email=a@b.com
  echo "enable default serviceaccount to use the pull secret"
  kubectl patch -n $CLUSTER_NAMESPACE serviceaccount/default -p '{"imagePullSecrets":[{"name":"'"$IMAGE_PULL_SECRET_NAME"'"}]}'
  echo "Namespace $CLUSTER_NAMESPACE is now authorized to pull from the private image registry"
fi
echo "default serviceAccount:"
kubectl get serviceAccount default -o yaml


# Check Helm/Tiller
echo "CHECKING TILLER (Helm's server component)"
helm init --upgrade
while true; do
tiller_deployed=$(kubectl --namespace=kube-system get pods | grep tiller | grep Running | grep 1/1 )
if [[ "${tiller_deployed}" != "" ]]; then
  echo "Tiller ready."
  break; 
fi
echo "Waiting for Tiller to be ready."
sleep 1
done
helm version

echo "CHECKING CHART (lint) "
helm lint ${RELEASE_NAME} ./chart/${CHART_NAME}

echo "DRY RUN DEPLOYING into: $PIPELINE_KUBERNETES_CLUSTER_NAME/$CLUSTER_NAMESPACE."
helm upgrade ${RELEASE_NAME} ./chart/${CHART_NAME} --namespace $CLUSTER_NAMESPACE --install --debug --dry-run

echo "DEPLOYING into: $PIPELINE_KUBERNETES_CLUSTER_NAME/$CLUSTER_NAMESPACE."
helm upgrade ${RELEASE_NAME} ./chart/${CHART_NAME} --namespace $CLUSTER_NAMESPACE --install

echo ""
echo "DEPLOYED SERVICE:"
kubectl describe services ${RELEASE_NAME}-${CHART_NAME} --namespace $CLUSTER_NAMESPACE

echo ""
echo "DEPLOYED PODS:"
kubectl describe pods --selector app=${CHART_NAME} --namespace $CLUSTER_NAMESPACE

port=$(kubectl get services --namespace $CLUSTER_NAMESPACE | grep ${RELEASE_NAME}-${CHART_NAME} | sed 's/.*:\([0-9]*\).*/\1/g')
echo ""
echo "VIEW THE APPLICATION AT: http://$ip_addr:$port"
