#!/bin/bash 
# Put this script into deploy folder, make sure you have prereq setup with correct pull-secret (acm-d)
TMP_DIR=$HOME/tmp
KUBECTL_CMD="oc --insecure-skip-tls-verify=true"
PACKAGEMANIFEST_CSVS=`$KUBECTL_CMD get packagemanifest advanced-cluster-management -n ${ACM_NAMESPACE} -o=jsonpath='{.status.channels[*].currentCSV}'`


function uninstallHub() {
	printf "UNINSTALL HUB\n"
	echo "DESTROY" | ./clean-clusters.sh
	bma_namespaces=`$KUBECTL_CMD get baremetalasset  --all-namespaces --ignore-not-found| awk '!a[$1]++ { if(NR>1) print $1 }'`
	for ns in $bma_namespaces; do 
			$KUBECTL_CMD delete baremetalasset --all -n $ns --ignore-not-found 
	done
	$KUBECTL_CMD project $ACM_NAMESPACE
	$KUBECTL_CMD delete mco --all --ignore-not-found 
	$KUBECTL_CMD delete mch --all --ignore-not-found 
	sleep 200
	$KUBECTL_CMD delete -k ./acm-operator 
	$KUBECTL_CMD delete csv advanced-cluster-management.$STARTING_CSV_VERSION 
	$KUBECTL_CMD delete -k ./prereqs 
	sleep 20

	# delete remaining resources if any
	$KUBECTL_CMD project $ACM_NAMESPACE 
	helm ls --namespace $ACM_NAMESPACE | cut -f 1 | tail -n +2 | xargs -n 1 helm delete --namespace $ACM_NAMESPACE
	$KUBECTL_CMD delete apiservice v1.admission.cluster.open-cluster-management.io v1beta1.webhook.certmanager.k8s.io
	$KUBECTL_CMD delete clusterimageset --all
	$KUBECTL_CMD delete configmap cert-manager-controller cert-manager-cainjector-leader-election cert-manager-cainjector-leader-election-core
	$KUBECTL_CMD delete consolelink acm-console-link
	$KUBECTL_CMD delete crd klusterletaddonconfigs.agent.open-cluster-management.io placementbindings.policy.open-cluster-management.io policies.policy.open-cluster-management.io userpreferences.console.open-cluster-management.io searchservices.search.acm.com
	$KUBECTL_CMD delete mutatingwebhookconfiguration cert-manager-webhook
	$KUBECTL_CMD delete oauthclient multicloudingress
	$KUBECTL_CMD delete rolebinding -n kube-system cert-manager-webhook-webhook-authentication-reader
	$KUBECTL_CMD delete scc kui-proxy-scc
	$KUBECTL_CMD delete validatingwebhookconfiguration cert-manager-webhook
	sleep 100
	
	./hack/nuke.sh
	sleep 100
}

function waitForInstallPlan() {
    version=$1
    for i in `seq 1 20`; do
        $KUBECTL_CMD get installplan -n ${ACM_NAMESPACE}  | grep "$version"
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
            $KUBECTL_CMD -n ${ACM_NAMESPACE} get pods 
            echo
            echo "You should see ${podName}, multiclusterhub-repo, and multicloud-operators-subscription pods"
            break
        fi
        if [ "$ignore" == "" ]; then
            operatorPod=`$KUBECTL_CMD -n ${ACM_NAMESPACE} get pods  | grep ${podName}`
        else
            operatorPod=`$KUBECTL_CMD -n ${ACM_NAMESPACE} get pods  | grep ${podName} | grep -v ${ignore}`
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
	rel_channel=`$KUBECTL_CMD get sub acm-operator-subscription -n $ACM_NAMESPACE -o jsonpath='{.spec.channel}' | cut -d "-" -f2`
	case $rel_channel in
	2.0*)
		TOTAL_POD_COUNT=55;;
	2.1*)
		TOTAL_POD_COUNT=56;;
	2.2*)
		TOTAL_POD_COUNT=60;;
	2.3*)
		TOTAL_POD_COUNT=57;;		
	esac
	
	for i in {1..20}; do	
		sleep 30
		whatsLeft=`$KUBECTL_CMD -n ${ACM_NAMESPACE} get pods  | grep -v -e "Completed" -e "1/1     Running" -e "2/2     Running" -e "3/3     Running" -e "4/4     Running" -e "5/5     Running" -e "READY   STATUS" | wc -l`
		#whatsLeft=`$KUBECTL_CMD -n ${ACM_NAMESPACE} get pods  | grep -v "Completed\|Running" | wc -l`
		RUNNING_PODS=$($KUBECTL_CMD -n ${ACM_NAMESPACE} get pods | grep -v -e "Completed" | tail -n +2 | wc -l | tr -d '[:space:]')
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
		$KUBECTL_CMD -n ${ACM_NAMESPACE} get pods | grep -v -e "Completed" -e "1/1     Running" -e "2/2     Running" -e "3/3     Running" -e "4/4     Running" -e "5/5     Running"
	fi
	CONSOLE_URL=`$KUBECTL_CMD -n ${ACM_NAMESPACE}  get routes multicloud-console -o jsonpath='{.status.ingress[0].host}' 2> /dev/null`
	echo "#####"
	echo "* Red Hat ACM URL: https://$CONSOLE_URL"
	echo "#####"
}

function waitForMCHReleases() {
    for i in {1..10}; do
		sleep 30
        numHelm=`helm ls -n ${ACM_NAMESPACE} | grep deployed | wc -l`
        if [ $numHelm -ge 11 ] ; then 
            echo 'All Helm releases installed'
            helm ls
            break 
        fi
        echo 'waiting for helm releases deployed...'        
    done
}

function waitForHelmReleases() {
	helmreleases=`$KUBECTL_CMD get helmreleases -n ${ACM_NAMESPACE} | awk '{ if(NR>1) print $1 }'`
	expectedReason=$([ "$UPGRADE_ONLY" == true ] && echo "UpgradeSuccessful" || echo "InstallSuccessful")
    for i in {1..10}; do
	    echo 'waiting for helm releases status'
		sleep 30
		for helm in $helmreleases; do  	
			reason=`$KUBECTL_CMD  get helmrelease -n ${ACM_NAMESPACE} $helm -o json | jq -r '.status.conditions[].reason | select(.)'`
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
        $KUBECTL_CMD  get csv -n ${ACM_NAMESPACE} advanced-cluster-management.$version | grep Succeeded 
        if [ $? -eq 0 ]; then
          break
        fi
        sleep 30
    done
}

function waitForLocalCluster() {
    for i in {1..10}; do
			sleep 30
      podCount=`$KUBECTL_CMD get pods -n open-cluster-management-agent-addon  | grep Running | wc -l`
      if [ $podCount -ge 7 ] ; then 
        echo 'All addons installed'
        break 
      fi
      echo 'waiting for agent addons deployed...'        
    done
}

function validateChartVersions() {
	# retrieve chart versions in GH
	pkg_name=`printf '%s\n' "${BUILD//DOWNSTREAM-/}"`
	curl -H "Authorization: token $GITHUB_TOKEN" -L https://github.com/open-cluster-management/multicloudhub-repo/archive/v$pkg_name.tar.gz -o $TMP_DIR/$BUILD.tar.gz
	tar -xf $TMP_DIR/$BUILD.tar.gz -C $TMP_DIR
	
	# compare chart versions
	printf "\nValidate installed chart versions ...\n"
	helmreleases=`$KUBECTL_CMD get helmrelease -n ${ACM_NAMESPACE}  | awk '{ if(NR>1) print $1 }'`
	for helmrelease in $helmreleases; do 
		chart_name=`echo ${helmrelease%-*}`
		chart_version=`$KUBECTL_CMD  get helmrelease -n ${ACM_NAMESPACE} $helmrelease -o=jsonpath='{.repo.version}'`
		chart_revision=`helm status $helmrelease -n ${ACM_NAMESPACE} | grep REVISION`
		expect_version=`yq .entries.\"$chart_name\"[].version $TMP_DIR/multicloudhub-repo-$pkg_name/multiclusterhub/charts/index.yaml | tr -d '"'`
		if [[ $chart_version != $expect_version ]]; then
			printf "Mismatched installed version of $chart_name -- expected $expect_version - actual $chart_version"
			break
		else	
			printf "$chart_name-$chart_version-$chart_revision -- OK\n"
		fi
	done
}

function validateDeployedImages() {
	printf "\nValidate deployed images ...\n"
	deploys=`$KUBECTL_CMD get deploy -n ${ACM_NAMESPACE} -o name  |grep -v acm-custom-registry`
	for deploy in $deploys; do
		deployed_image=`$KUBECTL_CMD  get -n ${ACM_NAMESPACE} -ojsonpath='{.spec.template.spec.containers[0].image}' $deploy | awk -F'/' '{print $3}'`
		if [ $($KUBECTL_CMD  get packagemanifest -n $ACM_NAMESPACE advanced-cluster-management -oyaml | grep "$deploy_image" | wc -l) -lt 1 ]; then
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
			$KUBECTL_CMD apply --openapi-patch=true -k prereqs/ 
			$KUBECTL_CMD project $ACM_NAMESPACE 
			if [[ $INGRESS_DOMAIN != 'none' ]]; then
				$KUBECTL_CMD create configmap custom-ca --from-file=ca-bundle.crt=$CERT_DIR/*.$INGRESS_DOMAIN.crt 
			fi
			
			printf "\nInstall acm operator ...\n"
			sed -i 's|^\(\s*newName\s*:\s*\).*|\1quay.io:443/acm-d/acm-custom-registry|' ./acm-operator/kustomization.yaml
			sed -i "s/^\(\s*newTag\s*:\s*\).*/\1$BUILD/" ./acm-operator/kustomization.yaml
			$KUBECTL_CMD apply -k ./acm-operator 
			waitForPod "acm-custom-registry" "" "1/1"	
			$KUBECTL_CMD apply -f ./acm-operator/subscription.yaml
		else 
			$KUBECTL_CMD project $ACM_NAMESPACE
			$KUBECTL_CMD apply -f ./acm-operator/subscription.yaml 
		fi	
		
		# wait for acm operator install completed
		waitForInstallPlan $1
		printf "Approve install plan...\n"
		$KUBECTL_CMD  patch installplan `$KUBECTL_CMD get installplan -n $ACM_NAMESPACE | grep $1 | cut -d' ' -f1` --type=merge -p '{"spec": {"approved": true} }'
		waitForPod "multiclusterhub-operator" "acm-custom-registry" "1/1"
		case $CSV_VERSION in
			v2.0*)
				waitForPod "multicluster-operators-application" "" "4/4";;		
			v2.1*)
				waitForPod "multicluster-operators-application" "" "4/4";;
			*)
				waitForPod "multicluster-operators-application" "" "5/5";;
		esac
		waitForCSV $1
		
		# create mch 
		if [ $($KUBECTL_CMD  get mch -o name| wc -l) -lt 1 ]; then
			printf "\nCreate MCH instance ...\n"
			sed -i 's|^\(\s*"mch-imageRepository"\s*:\s*\).*|\1"quay.io:443/acm-d"|' ./multiclusterhub/example-multiclusterhub-cr.yaml
			sed -i "s/^\(\s*namespace\s*:\s*\).*/\1$ACM_NAMESPACE/" ./multiclusterhub/example-multiclusterhub-cr.yaml
			$KUBECTL_CMD apply -f ./multiclusterhub/example-multiclusterhub-cr.yaml 
		fi
		
		# wait for install/upgrade completed
		waitForMCHReleases
		waitForHelmReleases
		waitForAllPods
		
		# wait for agent addon in >2.1
		if [ "2.1.0" = "`echo -e "$(echo ${CSV_VERSION#*v})\n2.1.0" | sort -V | head -n1`" ]; then
			waitForLocalCluster
		fi
			
		# increase upgraded-to csv version
		getNextInstallVersion
	
	fi
	printf "Install/upgrade Completed\n"
}

function getNextInstallVersion(){
	CURR_CSV_NAME=`$KUBECTL_CMD get csv -o name  | awk -F'[/]' '{print $2}'`
	CURR_CHANNEL=`echo ${CURR_CSV_NAME#*.} | awk -F'[v.]' '{print $2"."$3}'`
	CSVS=($PACKAGEMANIFEST_CSVS)
	
	if [[ "$CURR_CSV_NAME" == "${CSVS[-1]}" ]]; then
		CSV_VERSION='N/A'
	else
		if [[ "$PACKAGEMANIFEST_CSVS" == *"$CURR_CSV_NAME"* ]]; then
			echo -n "Latest version of channel $CURR_CHANNEL\n"
			CHANNEL=`echo $CURR_CHANNEL | awk -F. -v OFS=. '{$NF++;print}'`
			sed -i "s/^\(\s*channel\s*:\s*\).*/\1release-$CHANNEL/" ./acm-operator/subscription.yaml
			#CSV_VERSION=`echo v$CHANNEL".0"`
			CSV_VERSION=`echo v$BUILD | awk -F- '{print $1}'`
		else
			CSV_VERSION=`echo ${CURR_CSV_NAME#*.} | awk -F. -v OFS=. '{$NF++;print}'`
		fi
	fi	
}

#------------- main -------------
# uninstall if set
$KUBECTL_CMD project $ACM_NAMESPACE
sub_count=`$KUBECTL_CMD get sub -n $ACM_NAMESPACE | wc -l`
if [ $CLEANUP_INCLUDED != 'false' ] && [ $sub_count -gt 0 ]; then 
	uninstallHub 
fi
# install base version
if [ $UPGRADE_ONLY != 'true' ]; then
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
	#validateDeployedImages
fi