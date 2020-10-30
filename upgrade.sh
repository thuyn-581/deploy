#!/bin/bash 
# Put this script into deploy folder, make sure you have prereq setup with correct pull-secret (acm-d)
TOTAL_POD_COUNT=55 # 33 for basic 55 for high
TMP_DIR=$HOME/tmp

BASE_CHANNEL=`echo $STARTING_CSV_VERSION | awk -F'[v.]' '{print $2"."$3}'`
UPGRADE_CHANNEL=`echo $BUILD | awk -F'.' '{print $1"."$2}'`

PACKAGEMANIFEST_CSVS=`oc get packagemanifest advanced-cluster-management -n ${ACM_NAMESPACE} -o=jsonpath='{.status.channels[*].currentCSV}'`

function uninstallHub() {
	printf "UNINSTALL HUB\nDeleting MCH ...\n"
	echo "DESTROY" | ./clean-clusters.sh
	bma-namespaces=`oc get baremetalasset --all-namespaces | awk '!a[$1]++ { if(NR>1) print $1 }'`
	for ns in $bma-namespaces; do 
			oc delete baremetalasset --all -n $ns
	done
	kubectl delete mco --all
	kubectl delete mch --all
	echo 'Sleeping for 200 seconds to allow resources to finalize ...'
	sleep 200	
	./acm-operator/uninstall.sh	
	sleep 30
	./hack/nuke.sh

	# delete remaining resources if any
	oc project $ACM_NAMESPACE
	helm ls --namespace $ACM_NAMESPACE | cut -f 1 | tail -n +2 | xargs -n 1 helm delete --namespace $ACM_NAMESPACE
	oc delete apiservice v1.admission.cluster.open-cluster-management.io v1beta1.webhook.certmanager.k8s.io
	oc delete clusterimageset --all
	oc delete configmap cert-manager-controller cert-manager-cainjector-leader-election cert-manager-cainjector-leader-election-core
	oc delete consolelink acm-console-link
	oc delete crd klusterletaddonconfigs.agent.open-cluster-management.io placementbindings.policy.open-cluster-management.io policies.policy.open-cluster-management.io userpreferences.console.open-cluster-management.io searchservices.search.acm.com
	oc delete mutatingwebhookconfiguration cert-manager-webhook
	oc delete oauthclient multicloudingress
	oc delete rolebinding -n kube-system cert-manager-webhook-webhook-authentication-reader
	oc delete scc kui-proxy-scc
	oc delete validatingwebhookconfiguration cert-manager-webhook
	sleep 20
}

function waitForInstallPlan() {
    version=$1
    for i in `seq 1 20`; do
        oc get installplan | grep "$version"
        if [ $? -eq 0 ]; then
          break
        fi
        echo 'waiting for installplan to show'
        sleep 30
    done
}

function waitForPod() {
    FOUND=1
    MINUTE=0
    podName=$1
    ignore=$2
    running="$3"
    printf "\n#####\nWait for ${podName} to reach running state (4min).\n"
    while [ ${FOUND} -eq 1 ]; do
        if [ $MINUTE -gt 240 ]; then
            echo "Timeout waiting for the ${podName}. Try cleaning up using the uninstall scripts before running again."
            echo "List of current pods:"
            oc -n ${ACM_NAMESPACE} get pods
            echo
            echo "You should see ${podName}, multiclusterhub-repo, and multicloud-operators-subscription pods"
            break
        fi
        if [ "$ignore" == "" ]; then
            operatorPod=`oc -n ${ACM_NAMESPACE} get pods | grep ${podName}`
        else
            operatorPod=`oc -n ${ACM_NAMESPACE} get pods | grep ${podName} | grep -v ${ignore}`
        fi
        if [[ "$operatorPod" =~ "${running}     Running" ]]; then
            echo "* ${podName} is running"
            break
        elif [ "$operatorPod" == "" ]; then
            operatorPod="Waiting"
        fi
        echo "* STATUS: $operatorPod"
        sleep 3
        (( MINUTE = MINUTE + 3 ))
    done
}

function waitForAllPods() {
	COMPLETE=1
	for i in {1..20}; do	
		sleep 30
		whatsLeft=`oc -n ${ACM_NAMESPACE} get pods | grep -v -e "Completed" -e "1/1     Running" -e "2/2     Running" -e "3/3     Running" -e "4/4     Running" -e "READY   STATUS" | wc -l`
		RUNNING_PODS=$(oc -n ${ACM_NAMESPACE} get pods | grep -v -e "Completed" | tail -n +2 | wc -l | tr -d '[:space:]')
		if [ $RUNNING_PODS -eq ${TOTAL_POD_COUNT} ] && [ $whatsLeft -eq 0 ]; then
			COMPLETE=0
			break
		fi
		echo
		echo "Number of expected Pods : $RUNNING_PODS/$TOTAL_POD_COUNT"
		echo "Pods still NOT running  : ${whatsLeft}"		
	done		
	if [ $COMPLETE -eq 1 ]; then
		echo "At least one pod failed to start..."
		oc -n ${ACM_NAMESPACE} get pods | grep -v -e "Completed" -e "1/1     Running" -e "2/2     Running" -e "3/3     Running" -e "4/4     Running"
	fi
	CONSOLE_URL=`oc -n ${ACM_NAMESPACE} get routes multicloud-console -o jsonpath='{.status.ingress[0].host}' 2> /dev/null`
	echo "#####"
	echo "* Red Hat ACM URL: https://$CONSOLE_URL"
	echo "#####"
}

function waitForMCHReleases() {
    for i in {1..10}; do
		sleep 30
        numHelm=`helm ls | grep deployed | wc -l`
        if [ $numHelm -ge 11 ] ; then 
            echo 'All Helm releases installed'
            helm ls
            break 
        fi
        echo 'waiting for helm releases deployed'        
    done
}

function waitForHelmReleases() {
	helmreleases=`oc get helmreleases | awk '{ if(NR>1) print $1 }'`
	expectedReason=$([ "$UPGRADE_ONLY" == true ] && echo "UpgradeSuccessful" || echo "InstallSuccessful")
    for i in {1..10}; do
	    echo 'waiting for helm releases status'
		sleep 30
		for helm in $helmreleases; do  	
			reason=`oc get helmrelease $helm -o json | jq -r '.status.conditions[].reason | select(.)'`
			printf "$helm - $reason\n"
			if [[ -z "$reason" ]]; then
				continue
			elif [[ "$reason" != *"Successful"* ]]; then
				continue 2
				break
			fi
		done
		break 2
    done
}

function waitForCSV() {
    version=$1
    for i in `seq 1 5`; do
		echo 'waiting for csv to show'
        oc get csv advanced-cluster-management.$version | grep Succeeded 
        if [ $? -eq 0 ]; then
          break
        fi
        sleep 30
    done
}

function validateChartVersions() {
	# retrieve chart versions in GH
	pkg_name=`printf '%s\n' "${BUILD//DOWNSTREAM-/}"`
	curl -H "Authorization: token $GITHUB_TOKEN" -L https://github.com/open-cluster-management/multicloudhub-repo/archive/v$pkg_name.tar.gz -o $TMP_DIR/$BUILD.tar.gz
	tar -xf $TMP_DIR/$BUILD.tar.gz -C $TMP_DIR
	
	# compare chart versions
	printf "\nValidate installed chart versions ...\n"
	helmreleases=`oc get helmrelease | awk '{ if(NR>1) print $1 }'`
	for helmrelease in $helmreleases; do 
		chart_name=`echo ${helmrelease%-*}`
		chart_version=`oc get helmrelease $helmrelease -o=jsonpath='{.repo.version}'`
		expect_version=`yq .entries.\"$chart_name\"[].version $TMP_DIR/multicloudhub-repo-$pkg_name/multiclusterhub/charts/index.yaml | tr -d '"'`
		if [[ $chart_version != $expect_version ]]; then
			printf "Mismatched installed version of $chart_name -- expected $expect_version - actual $chart_version"
			break
		else	
			printf "$chart_name-$chart_version -- OK\n"
		fi
	done
}

function validateDeployedImages() {
	printf "\nValidate deployed images ...\n"
	deploys=`oc get deploy -o name |grep -v acm-custom-registry`
	for deploy in $deploys; do
		deployed_image=`oc get  -ojsonpath='{.spec.template.spec.containers[0].image}' $deploy | awk -F'/' '{print $3}'`
		if [ $(oc get packagemanifest -n $ACM_NAMESPACE advanced-cluster-management -oyaml | grep "$deploy_image" | wc -l) -lt 1 ]; then
			printf "Deployed image $deployed_image NOT found in acm packagemanifest"
			break;
		else 
			printf "$deployed_image -- OK\n"
		fi	 
	done
}

function installHub() {
	printf "\nInstall/Upgrade started ...\n"
	
	# install acm operator
	if [ $1 == "latest" ]; then
		export COMPOSITE_BUNDLE=true
		export CUSTOM_REGISTRY_REPO="quay.io:443/acm-d"
		echo $BUILD | ./start.sh
	else
		if [ $CSV_VERSION == $STARTING_CSV_VERSION ]; then
			printf "Set subscription channel ...\n"
			CHANNEL=`echo $1 | awk -F'[v.]' '{print $2"."$3}'`
			sed -i "s/^\(\s*channel\s*:\s*\).*/\1release-$CHANNEL/" ./acm-operator/subscription.yaml
			
			printf "Switch subscription approval plan to manual ...\n"
			sed -i "s/^\(\s*installPlanApproval\s*:\s*\).*/\1Manual/" ./acm-operator/subscription.yaml
			
			printf "Set subscrition starting version ...\n"
			LINE_COUNT=`awk '/startingCSV/{ print NR; exit }' ./acm-operator/subscription.yaml | wc -l`
			if [ $LINE_COUNT -lt 1 ]; then
				sed -i "/sourceNamespace/a\ \ startingCSV: advanced-cluster-management.$1" ./acm-operator/subscription.yaml
			else
				sed -i "s/advanced-cluster-management.v.*/advanced-cluster-management.$1/g" ./acm-operator/subscription.yaml
			fi
			
			printf 'Apply preregs ...\n'
			kubectl apply --openapi-patch=true -k prereqs/
			oc project $ACM_NAMESPACE
					
			printf "\nInstall acm operator ...\n"
			sed -i 's|^\(\s*newName\s*:\s*\).*|\1quay.io:443/acm-d/acm-custom-registry|' ./acm-operator/kustomization.yaml
			sed -i "s/^\(\s*newTag\s*:\s*\).*/\1$BUILD/" ./acm-operator/kustomization.yaml
			kubectl apply -k ./acm-operator
		else 
			oc project $ACM_NAMESPACE
			kubectl apply -f ./acm-operator/subscription.yaml
		fi	
		
		# wait for acm operator install completed
		waitForInstallPlan $1
		printf "Approve install plan...\n"
		oc patch installplan `oc get installplan | grep $1 | cut -d' ' -f1` --type=merge -p '{"spec": {"approved": true} }'
		waitForPod "multiclusterhub-operator" "acm-custom-registry" "1/1"
		waitForPod "multicluster-operators-application" "" "4/4"	
		waitForCSV $1
		
		# create mch 
		if [ $(oc get mch -o name| wc -l) -lt 1 ]; then
			printf "\nCreate MCH instance ...\n"
			sed -i 's|^\(\s*"mch-imageRepository"\s*:\s*\).*|\1"quay.io:443/acm-d"|' ./multiclusterhub/example-multiclusterhub-cr.yaml
			kubectl apply -f ./multiclusterhub/example-multiclusterhub-cr.yaml
		fi
		
		# wait for install/upgrade completed
		waitForMCHReleases
		waitForHelmReleases
		waitForAllPods
			
		# increase upgraded-to csv version
		getNextInstallVersion
	
	fi
	printf "Install/upgrade Completed\n"
}

function getNextInstallVersion(){
	CURR_CSV_NAME=`oc get csv -o name| awk -F'[/]' '{print $2}'`
	CURR_CHANNEL=`echo ${CURR_CSV_NAME#*.} | awk -F'[v.]' '{print $2"."$3}'`

	if [[ "$PACKAGEMANIFEST_CSVS" == *"$CURR_CSV_NAME"* ]]; then
		echo -n "Latest version of channel $CURR_CHANNEL"
		CHANNEL=`echo $CURR_CHANNEL | awk -F. -v OFS=. '{$NF++;print}'`
		sed -i "s/^\(\s*channel\s*:\s*\).*/\1release-$CHANNEL/" ./acm-operator/subscription.yaml
		CSV_VERSION=`echo v$CHANNEL".0"`
	else
		CSV_VERSION=`echo ${CURR_CSV_NAME#*.} | awk -F. -v OFS=. '{$NF++;print}'`
	fi
}

#------------- main -------------
# uninstall if set
mch_count=`oc get mch -n $ACM_NAMESPACE | wc -l`
if [ $CLEANUP_INCLUDED != 'false' ] && [ $mch_count -gt 0 ]; then 
	uninstallHub 
fi
# install base version
if [ $UPGRADE_ONLY != 'true' ]; then
  if [ $INGRESS_CERT_ENABLED == 'true' ]; then
		printf "\nCreate custom CA configmap in $ACM_NAMESPACE"	
		oc create configmap custom-ca \
      --from-file=ca-bundle.crt=$CERT_DIR/*.$INGRESS_DOMAIN.crt \
      -n $ACM_NAMESPACE
	fi
	printf "\nInstall base version $STARTING_CSV_VERSION"	
	installHub $STARTING_CSV_VERSION
else
	getNextInstallVersion
	
	v1=$(echo ${CSV_VERSION#*v})
	v2=$(echo `printf "${BUILD%%-*}"`| awk -F. -v OFS=. '{$NF;print}')
	while [ "$v1" = "`echo -e "$v1\n$v2" | sort -V | head -n1`" ]
	do
		#upgrade
		printf "\nUpgrade Hub to $CSV_VERSION"
		installHub $CSV_VERSION 
		v1=$(echo ${CSV_VERSION#*v})
	done
	sleep 10
	validateChartVersions
	validateDeployedImages
fi