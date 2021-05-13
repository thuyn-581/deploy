#!/bin/bash 
# Put this script into deploy folder, make sure you have prereq setup with correct pull-secret (acm-d)

KUBECTL_CMD_CMD="oc --insecure-skip-tls-verify=true"

cleanClusters(){
	if [ -z "${OPERATOR_NAMESPACE}" ]; then
		OPERATOR_NAMESPACE="open-cluster-management-agent-addon"
	fi

	if [ -z "${KLUSTERLET_NAMESPACE}" ]; then
		KLUSTERLET_NAMESPACE="open-cluster-management-agent"
	fi
	echo "DESTROY" | ./clean-clusters.sh
	# Force delete klusterlet
	echo "attempt to delete klusterlet"
	${KUBECTL_CMD} delete klusterlet klusterlet --timeout=60s
	${KUBECTL_CMD} delete namespace ${KLUSTERLET_NAMESPACE} --wait=false
	echo "force removing klusterlet"
	${KUBECTL_CMD} patch klusterlet klusterlet --type="json" -p '[{"op": "remove", "path":"/metadata/finalizers"}]'
	echo "removing klusterlet crd"
	${KUBECTL_CMD} delete crd klusterlets.operator.open-cluster-management.io --timeout=30s

	# Force delete all component CRDs if they still exist
	component_crds=(
		applicationmanagers.agent.open-cluster-management.io
		certpolicycontrollers.agent.open-cluster-management.io
		iampolicycontrollers.agent.open-cluster-management.io
		policycontrollers.agent.open-cluster-management.io
		searchcollectors.agent.open-cluster-management.io
		workmanagers.agent.open-cluster-management.io
		appliedmanifestworks.work.open-cluster-management.io
	)

	for crd in "${component_crds[@]}"; do
		echo "force delete all CustomResourceDefinition ${crd} resources..."
		for resource in `${KUBECTL_CMD} get ${crd} -o name -n ${OPERATOR_NAMESPACE}`; do
			echo "attempt to delete ${crd} resource ${resource}..."
			${KUBECTL_CMD} delete ${resource} -n ${OPERATOR_NAMESPACE} --timeout=30s
			echo "force remove ${crd} resource ${resource}..."
			${KUBECTL_CMD} patch ${resource} -n ${OPERATOR_NAMESPACE} --type="json" -p '[{"op": "remove", "path":"/metadata/finalizers"}]'
		done
		echo "force delete all CustomResourceDefinition ${crd} resources..."
		${KUBECTL_CMD} delete crd ${crd}
	done

	${KUBECTL_CMD} delete namespace ${OPERATOR_NAMESPACE}
}

uninstallHub() {
	printf "UNINSTALL HUB in $1\n"
	echo 'Delete bma...'
	bma_nss=`$KUBECTL_CMD_CMD get baremetalasset  --all-namespaces --ignore-not-found| awk '!a[$1]++ { if(NR>1) print $1 }'`
	for ns in $bma_nss; do 
			$KUBECTL_CMD_CMD delete baremetalasset --all -n $ns --ignore-not-found 
	done
	echo 'Delete mco...'
	$KUBECTL_CMD_CMD project $1
	$KUBECTL_CMD_CMD delete mco --all --ignore-not-found 
	sleep 10
	echo 'Delete discoconfig...'
	discocfg_nss=`$KUBECTL_CMD_CMD get discoveryconfig --all-namespaces --ignore-not-found| awk '!a[$1]++ { if(NR>1) print $1 }'`
	for ns in $discocfg_nss; do 
			$KUBECTL_CMD_CMD delete discoveryconfig --all -n $ns --ignore-not-found 
	done
	echo 'Delete mch...'
	$KUBECTL_CMD_CMD delete mch --all --ignore-not-found 
	echo 'Wait 200s...'
	sleep 200
	$KUBECTL_CMD_CMD delete -k ./acm-operator 
	$KUBECTL_CMD_CMD delete csv advanced-cluster-management.$STARTING_CSV_VERSION 
	$KUBECTL_CMD_CMD delete -k ./prereqs 
	echo 'Wait 100s...'
	sleep 100

	# delete remaining resources if any
	echo 'delete remaining resources...'
	$KUBECTL_CMD_CMD project $1 
	helm ls --namespace $1 | cut -f 1 | tail -n +2 | xargs -n 1 helm delete --namespace $1
	$KUBECTL_CMD_CMD delete apiservice v1.admission.cluster.open-cluster-management.io v1beta1.webhook.certmanager.k8s.io
	$KUBECTL_CMD_CMD delete clusterimageset --all
	$KUBECTL_CMD_CMD delete configmap cert-manager-controller cert-manager-cainjector-leader-election cert-manager-cainjector-leader-election-core
	$KUBECTL_CMD_CMD delete consolelink acm-console-link
	$KUBECTL_CMD_CMD delete crd klusterletaddonconfigs.agent.open-cluster-management.io placementbindings.policy.open-cluster-management.io policies.policy.open-cluster-management.io userpreferences.console.open-cluster-management.io searchservices.search.acm.com
	$KUBECTL_CMD_CMD delete mutatingwebhookconfiguration cert-manager-webhook
	$KUBECTL_CMD_CMD delete oauthclient multicloudingress
	$KUBECTL_CMD_CMD delete rolebinding -n kube-system cert-manager-webhook-webhook-authentication-reader
	$KUBECTL_CMD_CMD delete scc kui-proxy-scc
	$KUBECTL_CMD_CMD delete validatingwebhookconfiguration cert-manager-webhook
	sleep 100
	
	echo 'run nuke script...'
	./hack/nuke.sh
	sleep 100
}


cleanClusters
uninstallHub $1
