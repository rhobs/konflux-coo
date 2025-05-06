#!/bin/bash
# run like so:
# ./hack/image-mirror.sh -idms_stage | -idms | -icsp_stage | -icsp

#Create when testing with bundle/FBC stage release images
#OCP 4.12 and previous version
icsp_stage() { 
    cat <<EOF | oc create -f -
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: icsp-stage-coo
spec:
  repositoryDigestMirrors:
  - mirrors:
    - registry.stage.redhat.io
    source: registry.redhat.io
EOF
}

#Create before testing bundle/FBC images before stage release
#OCP 4.12 and previous version
icsp_quay() {    
    cat <<EOF | oc create -f -
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: icsp-quay-coo
spec:
  repositoryDigestMirrors:
  - mirrors:
    - quay.io/redhat-user-workloads/cluster-observabilit-tenant/cluster-observability-operator
    source: registry.redhat.io/cluster-observability-operator
EOF
}

#Create when testing with bundle/FBC stage release images
#OCP 4.13 and later version
idms_stage() {
    cat <<EOF | oc apply -f -
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: idms-stage-coo
spec:
  imageDigestMirrors:
  - mirrors:
    - registry.stage.redhat.io
    source: registry.redhat.io
EOF
}

#Create before testing bundle/FBC images before stage release
#OCP 4.13 and later version
idms_quay() {
    oc apply -f - <<EOF
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: idms-quay-coo
spec:
  imageDigestMirrors:
  - mirrors:
    - quay.io/redhat-user-workloads/cluster-observabilit-tenant/cluster-observability-operator
    source: registry.redhat.io/cluster-observability-operator
EOF
}

if [[ -n "${1+xxx}" ]]; then
	case $1 in
	-icsp)
		icsp_quay
		;; 
	-icsp_stage)
		icsp_stage
		;;
	-idms)
		idms_quay
		;;
	-idms_stage)
		idms_stage
		;;
	*) echo 'Parameter must be -icsp, -icsp_stage or -idms, -idms_stage' ;; 
	esac
else
	echo 'Parameter must be -icsp, -icsp_stage or -idms, -idms_stage'
fi
