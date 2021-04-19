#!/bin/bash
set -e

# ENV Variables
# Number of test rounds
NTESTS=${NTESTS:-1000} ###########################################
# If we exit on the first failed test round
FAIL_ON_ERROR=${FAIL_ON_ERROR:-"y"}
# Output file
OUT_FILE=${OUT_FILE:-"/tmp/kata_longevity_test-$(date +%Y%m%d%H%M%S)"}
# Waiting timeout for command to complete
WAIT_TIMEOUT=${WAIT_TIMEOUT:-"180s"}

# Global vars
NERRORS=0
NROUNDS=0
TEST=0 #TEST COUNTER
# Test vars
TESTURL="test1.testing.apps.cluster1.kata.snir.com"
TESTFILE="/test/testfile"
RUNTIME_CLASS="kata-oc"
NAMESPACE=${NAMESPACE:-"longevity-$(cat /dev/urandom | tr -dc '0-9' | fold -w 256 | head -n 1 | sed -e 's/^0*//' | head --bytes 3)"}

#TODO node selector?
# write log to file and stdout
kata_logevity_log() {
    local level=$1
    shift
    echo "[$(date -R)] $level $@" | tee --append $OUT_FILE
}

# run and dump the cmds which follows. comma sperated
# otherwise will dump info on all non-ready pods
kata_logevity_dump_cmds() {
    kata_logevity_log DUMP "vvvvvvvvvv START DUMP vvvvvvvvvvvvvvvvvvvv"
    local dump_commands=("ocn get pods")
    if [[ -n $1 ]]; then
        IFS=',' read -ra dump_commands <<< "$@"
    else
        #dump info on not ready pods
        #for pod in $(ocn get pod | grep -v NAME | awk  -F' *|/' '$2 != $3 {print $1}') ; do
        for pod in $(ocn get pod | grep -v NAME | awk '{print $1}') ; do
            dump_commands+=("ocn logs ${pod} ")
            dump_commands+=("ocn describe pod ${pod} ")
            dump_commands+=("ocn exec ${pod} -- stat /proc/1/cmdline") # Container version of uptime
        done
    fi
        
    for cmd in "${dump_commands[@]}"; do
        kata_logevity_log DUMP "Running cmd: $cmd"
        local out=$(eval $cmd 2>&1 || true)
        local ret=$?
        kata_logevity_log DUMP "ret = $ret";
        kata_logevity_log DUMP "output = $out";
    done
    kata_logevity_log DUMP "ʌʌʌʌʌʌʌʌʌʌ END DUMP ʌʌʌʌʌʌʌʌʌʌʌʌʌʌʌʌʌʌʌʌʌʌ"
}

# dump before error
kata_logevity_error() {
    kata_logevity_log ERROR $@

    if [[ "${FAIL_ON_ERROR}" == "y" ]]; then
        kata_logevity_log "Stopping test $TEST at round ${NROUNDS}"
        echo "Output written to $OUT_FILE"
        exit 1
    else
        NERRORS=$((NERRORS+1))
    fi
}

login(){
    if [ -z "$KUBECONFIG" ]; then
        echo "KUBECONFIG not set"
        exit 1
    fi
    if [ -z "$KUBEADMIN_PASSFILE" ]; then
        kata_logevity_error "No kubeadmin password file. Use KUBEADMIN_PASSFILE to enable auto-login"
        exit 1
    else
        ocn login -u kubeadmin -p `cat $KUBEADMIN_PASSFILE` > /dev/null
        if [[ $? -eq 0 ]];  then
            kata_logevity_log INFO  "login preformed"
        else
            kata_logevity_error "login failed"
            exit 1
        fi
    fi
}

external_pod_probe() {
   local podname=$1
   local testfile=${2:-"/"}

   echo "Probe pod/${podname}, ${TESTURL}${file_path}"

   sleep 2
   #ocn exec pod/${podname} -- python3 -m  http.server  8080 --directory /
   ocn expose pod/${podname} --type="ClusterIP" --port 80 --target-port=8080
   if [[ $? -gt 0 ]]; then
       kata_logevity_dump_cmds ocn describe pod/$i
       kata_logevity_log WARN "Failed to expose pod service internally"
   fi

   #ocn expose service ${podname} --hostname=${TESTURL} --path=$(dirname ${testfile})
   ocn expose service ${podname} --hostname=${TESTURL} --path="/"
   if [[ $? -gt 0 ]]; then
       kata_logevity_dump_cmds ocn describe pod/$i
       kata_logevity_log WARN "Failed to expose pod route externally"
   fi

   sleep 5 # tries
   wget ${TESTURL}${testfile} -O /dev/null
   if [[ $? -gt 0 ]]; then
       kata_logevity_dump_cmds ocn describe pod/$i
       kata_logevity_log WARN "Failed to get web page"
   fi
   # delete

   ocn delete route ${podname} --wait --timeout=${WAIT_TIMEOUT}
   if [[ $? -gt 0 ]]; then
        kata_logevity_dump_cmds ocn describe pod/$i 
        kata_logevity_pod_error "Failed to delete route (stale pod $i)"
   fi
   ocn delete svc ${podname} --wait --timeout=${WAIT_TIMEOUT}
   if [[ $? -gt 0 ]]; then
        kata_logevity_dump_cmds ocn describe pod/$i 
        kata_logevity_pod_error "Failed to delete svc (stale pod $i)"
   fi
    
}

# [cpu/mem/single], sequence
# generic_test_loop <cpu|mem>, <sequence of matching values>
generic_test_loop() {
    local test_type=$1 #check
    local pod_name=${test_type//_/-}-test #valid pod name
    local test_cnt=0
    shift
    
    while (( ++test_cnt <= $NTESTS)); do
        kata_logevity_log INFO  "------ Running ${test_type} Test #${TEST}--------- "

            for i in ${@} ; do
            # apply
            kata_logevity_log INFO  "Trying to run pod with $i ${test_type} request"
            ${test_type}_test_file ${pod_name} $i | ocn apply -f - --wait 
            ocn wait --for=condition=Ready pod --all --timeout=${WAIT_TIMEOUT}
            if [[ $? -gt 0 ]]; then
                kata_logevity_dump_cmds ocn describe pod/${pod_name}
                kata_logevity_error "Failed to start pod (stale pod $i)"
            fi
            sleep 2
            external_pod_probe ${pod_name} ${TESTFILE}

            # delete
            ${test_type}_test_file ${pod_name} $i | ocn delete --wait --timeout=${WAIT_TIMEOUT} -f -
            if [[ $? -gt 0 ]]; then
                kata_logevity_dump_cmds ocn describe pod/${pod_name} 
                kata_logevity_pod_error "Failed to delete pod (stale pod ${pod_name})"
            fi
        done
        kata_logevity_log INFO  "------ Testing #${test_cnt} Complete --------- "
    done
    kata_logevity_log INFO "--------Finished ${test_type} $TEST tests Total Rounds ${NROUNDS} Errors: ${NERRORS} --------"
}

scale_loop(){
    local test_type="scale" #check
    local dep_name=${test_type//_/-}-test #valid pod name
    local test_cnt=1
    shift
    
    ${test_type}_test_file ${dep_name} 0 | ocn apply -f - --wait # or 0?
    sleep 2

    ocn expose deployment/${dep_name} --type="ClusterIP" --port 80 --target-port=8080
    if [[ $? -gt 0 ]]; then
        kata_logevity_dump_cmds ocn describe pod/$i
        kata_logevity_log WARN "Failed to expose pod service internally"
    fi

    ocn expose service ${dep_name} --hostname=${TESTURL} --path="/"
    if [[ $? -gt 0 ]]; then
        kata_logevity_dump_cmds ocn describe deployment/$i
        kata_logevity_log WARN "Failed to expose pod route externally"
    fi

    while (( ++test_cnt <= $NTESTS)); do
        kata_logevity_log INFO  "------ Running ${test_type} Test #${TEST}--------- "
        # apply
        kata_logevity_log INFO  "Trying to run deplyment with $i ${test_type} request"
        ${test_type}_test_file ${dep_name} $i | ocn apply -f - --wait 
        ocn wait --for=condition=Ready pod --all --timeout=${WAIT_TIMEOUT}
        if [[ $? -gt 0 ]]; then # print all stale pods
            kata_logevity_dump_cmds ocn describe deployment/${dep_name}
            kata_logevity_error "Failed to start deployment (stale pod ${dep_name})"
        fi
        kata_logevity_log INFO  "------ Testing #${test_cnt} Complete --------- "
    done
    # delete
    oc delete route ${dep_name}
    oc delete svc ${dep_name}
    ${test_type}_test_file ${dep_name} $i | ocn delete --wait --timeout=${WAIT_TIMEOUT} -f -
    if [[ $? -gt 0 ]]; then
        kata_logevity_dump_cmds ocn describe dep/$i 
        kata_logevity_pod_error "Failed to delete pod (stale pod $i)"
    fi
    ocn get pods
    kata_logevity_log INFO "--------Finished ${test_type} $TEST tests Total Rounds ${NROUNDS} Errors: ${NERRORS} --------"
}

scale_test_file() {
    local name=${1:-"mem-test"}
    local rep=$2
    local testfiledir=$(dirname ${TESTFILE})

cat << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
spec:
  selector:
    matchLabels:
      app: ${name}
  replicas: ${rep} 
  template:
    metadata:
      labels:
        app: ${name}
    spec:
      containers:
        - name: ${name}
          image: fedora
          ports:
            - containerPort: 8080
          command: ["/bin/sh","-c"]
          args: ["mkdir -p ${testfiledir} && touch ${TESTFILE} ; python3 -m http.server 8080 --directory / "]
          resources:
      runtimeClassName: ${RUNTIME_CLASS}
EOF
}

mem_test_file() {
    local name=${1:-"mem-test"}
    local mem=$2
    local testfiledir=$(dirname ${TESTFILE})

cat << EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  labels:
    app: ${name}-app
spec:
  containers:
    - name: ${name}
      image: fedora
      ports:
        - containerPort: 8080
      command: ["/bin/sh","-c"]
      args: ["mkdir -p ${testfiledir} && touch ${TESTFILE} ; python3 -m http.server 8080 --directory / "]
      resources:
        requests:
          memory: ${mem}
  runtimeClassName: ${RUNTIME_CLASS}
EOF
}

cpu_test_file() {
    local name=${1:-"cpu-test"}
    local cpus=$2
    local testfiledir=$(dirname ${TESTFILE})

cat << EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  labels:
    app: ${name}-app
spec:
  containers:
    - name: ${name}
      image: fedora
      ports:
        - containerPort: 8080
      command: ["/bin/sh","-c"]
      args: ["mkdir -p ${testfiledir} && touch ${TESTFILE} ; python3 -m http.server 8080 --directory / "]
      resources:
        requests:
          cpu: ${cpus}
  runtimeClassName: ${RUNTIME_CLASS}
EOF
}

vol_emptydir_test_file() {
    local name=${1:-"vol-test-emptydir"}
    local testfiledir=$(dirname ${TESTFILE})

cat << EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  labels:
    app: ${name}-app
spec:
  containers:
    - name: ${name}
      image: fedora
      ports:
        - containerPort: 8080
      command: ["/bin/sh","-c"]
      args: ["truncate -s 320M ${TESTFILE} && python3 -m http.server 8080 --directory / "]
      volumeMounts:
### emptyDir mnt
      - mountPath: ${testfiledir}
        name: emptydir-volume
  volumes:
### emptyDir cfg should be deleted upon pod deletion
  - name: emptydir-volume
    emptyDir: {}
  runtimeClassName: ${RUNTIME_CLASS}
EOF
}

vol_emptydir_mem_test_file() {
    local name=${1:-"vol-test-emptydir-mem"}
    local testfiledir=$(dirname ${TESTFILE})

cat << EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  labels:
    app: ${name}-app
spec:
  containers:
    - name: ${name}
      image: fedora
      ports:
        - containerPort: 8080
      command: ["/bin/sh","-c"]
      args: ["truncate -s 320M ${TESTFILE} && python3 -m http.server 8080 --directory / "]
      volumeMounts:
### emptyDirmem mnt
      - mountPath: ${testfiledir}
        name: emptydir-volume-mem
  volumes:
### emptyDir Mem cfg should be deleted upon pod deletion
  - name: emptydir-volume-mem
    emptyDir:
      medium: Memory
  runtimeClassName: ${RUNTIME_CLASS}
EOF
}

vol_hostpath_test_file() {
    local name=${1:-"vol-test-hostpath"}
    local testfiledir=$(dirname ${TESTFILE})

cat << EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  labels:
    app: ${name}-app
spec:
  containers:
    - name: ${name}
      image: fedora
      ports:
        - containerPort: 8080
      command: ["/bin/sh","-c"]
      args: ["truncate -s 320M ${TESTFILE} && python3 -m http.server 8080 --directory / "]
      volumeMounts:
### hostPath mnt
      - mountPath: ${testfiledir}
        name: hostpath-volume-dir
  volumes:
#### hostPath cfg
  - name: hostpath-volume-dir
    hostPath:
      path: /tmp/hpdir-node
      type: DirectoryOrCreate
# clear
      lifecycle:
        preStop:
          exec:
            command: ["/bin/sh","-c","rm -rf ${testfiledir}"]
  runtimeClassName: ${RUNTIME_CLASS}
EOF
}

#oc with tries and timeout*try
ocn(){

    tries=2
    returncode=1

    for i in $(seq $tries); do #tries
        set +e
        # trick to capture stdout & stderr into vars
        result=$(
            { stdout=$(oc $@); returncode=$?; } 2>&1
            printf "this is the separator"
            printf "%s\n" "$stdout"
            exit "$returncode"
        )
        returncode=$?

        var_out=${result#*this is the separator}
        var_err=${result%this is the separator*}

        echo "#$returncode : $var_err"
        set -e
        if [[ $returncode -eq 0 ]]; then
            if [[ -n $var_out ]]; then
                echo "$var_out"
            fi
            if [[ -n $var_err ]]; then
                echo "$var_err" >/dev/stderr
            fi
            return 0
        elif [[ -n $(echo "$var_err" | grep "must be logged in") ]]; then
            kata_logevity_log INFO  "oc command \"oc $@\" failed due to login issue, try to login and execute"
            login
        else
            break
        fi
    done
    kata_logevity_log "ERROR" "\"oc $@\" cmd failed and returned $returncode"
    if [ -n "$var_err" ]; then
        kata_logevity_log "     " "stderr: $var_err"
    fi
    if [ -n "$var_out" ]; then
        kata_logevity_log "     " "stdout: $var_out"
    fi
    echo "$var_out"
    echo "$var_err" >/dev/stderr
    return $returncode
}

helpmsg() {
    local opt
    for opt in "$@" ; do
	echo "Unknown option $opt"
    done
cat <<EOF
Usage: $0 <test-type> [arg_list] [options]
  Test Types:
    all               Run all tests in sequence, with default values.
    memory            Test set of memory requests. [100M, 1G, 2G...]
    cpu               Test set of cpu requests. [0.5, 1, 1.5 ...]
    emptydir          Test EmptyDir volume.
    emptydir-mem      Test EmptyDir Memory based volume.
    hostpath          Test HostPath Volume.
    scale             Test scaling to a set of replica numbers. [1, 2, 6 ...]
    volumes           Preform all volume types tests in sequence.

  options:
    -n, --namespace   Namespace to use
    -r, --rouds       Number of rounds per test
    -u, --url         Valid domain for testing webserver response
    -h, --help        Print this help message
EOF
}

# print all
PARAMS=""
while (( "$#" )); do
  case "$1" in
    -h|--help)
      helpmsg
      exit 0
      ;;
    -n|--namespace)
      if [ -n "$2" ] && [ ${2:0:1} != "-" ]; then
        NAMESPACE=$2
        shift 2
      else
        echo "Error: Argument for $1 is missing" >&2
        exit 1
      fi
      ;;
    -u|--url)
      if [ -n "$2" ] && [ ${2:0:1} != "-" ]; then
        TESTURL=$2
        shift 2
      else
        echo "Error: Argument for $1 is missing" >&2
        exit 1
      fi
      ;;
    -r|--rounds)
      if [ -n "$2" ] && [ ${2:0:1} != "-" ]; then
        NTESTS=$2
        shift 2
      else
        echo "Error: Argument for $1 is missing" >&2
        exit 1
      fi
      ;;
    -*|--*) # unsupported flags
      helpmsg $1
      exit 1
      ;;
    *) # preserve positional arguments
      PARAMS="$PARAMS $1"
      shift
      ;;
  esac
done
echo "### Parameteres ###"
echo "Namespace: ${NAMESPACE}"
echo "Test URL: ${TESTURL}"
echo "Number of rounds: ${NTESTS}"
echo "###################"

# set positional arguments in their proper place
eval set -- "$PARAMS"

declare -a tests_arr
case "$1" in
  all*|All*)
    echo "$@ MATCH volumes|Volumes|vol|Vol|vols|Vols"
    tests_arr+=("generic_test_loop mem 1M 2M 100M")
    tests_arr+=("generic_test_loop cpu 0 0.5 0.8")
    tests_arr+=("scale_loop scale 1 2 3 4")
    tests_arr+=("generic_test_loop vol_emptydir 1")
    tests_arr+=("generic_test_loop vol_emptydir_mem 1")
    tests_arr+=("generic_test_loop vol_hostpath 1")
    shift
    ;;
  volumes|Volumes|vol|Vol|vols|Vols)
    echo "$@ MATCH volumes|Volumes|vol|Vol|vols|Vols"
    tests_arr+=("generic_test_loop vol_emptydir 1")
    tests_arr+=("generic_test_loop vol_emptydir_mem 1")
    tests_arr+=("generic_test_loop vol_hostpath 1")
    shift
    ;;
  mem*|Mem*)
    echo "$@ MATCH mem*|Mem*"
    if [ -n "$2" ]; then
      shift 1
      tests_arr+=("generic_test_loop mem $@")
    else
      tests_arr+=("generic_test_loop mem 1M 2M 100M")
    fi
    ;;
  cpu*|Cpu*|CPU*)
    echo "$@ MATCH cpu*|Cpu*|CPU*"
    if [ -n "$2" ]; then
      shift 1
      tests_arr+=("generic_test_loop cpu $@")
    else
      tests_arr+=("generic_test_loop cpu 0 0.5 0.8") # check what is the max
    fi
    ;;
  scale*|Scale*)
    echo "$@ scale*|Scale*"
    if [ -n "$2" ]; then
      shift 1
      tests_arr+=("scale_loop scale $@")
    else
      tests_arr+=("scale_loop scale 1 2 3 4")
    fi
    ;;
  *Empty*Dir|*empty*dir)
    echo "$@ *Empty*Dir|*empty*dir"
    tests_arr+=("generic_test_loop vol_emptydir 1") # fix this stupidy
    ;;
  *Empty*Dir*Mem|*empty*dir*mem)
    echo "$@ *Empty*Dir*Mem|*empty*dir*mem"
    tests_arr+=("generic_test_loop vol_emptydir_mem 1") # fix this stupidy
    ;;
  *host*path|*Host*Path)
    echo "$@ *host*path|*Host*Path"
    tests_arr+=("generic_test_loop vol_hostpath 1") # fix this stupidy
    ;;
  *) # preserve positional arguments
      helpmsg $@
      exit 0
    ;;
esac

oc create namespace ${NAMESPACE}
oc config set-context --current --namespace=${NAMESPACE}
kata_logevity_log INFO  "========== Testing namespace: ${NAMESPACE}========== "

for i in "${tests_arr[@]}"; do
  echo "$i"
  $i
done

#ocn get pods ; exit 1
#generic_test_loop vol_emptydir 1
#generic_test_loop vol_emptydir_mem 1
#generic_test_loop vol_hostpath 1
#generic_test_loop cpu $(seq 0 0.1 0.7)
#generic_test_loop mem 1M 2M 100M
scale_loop scale 1 2 3

oc delete ns ${NAMESPACE}

# copy to exit?
kata_logevity_log INFO  "========== !!! Don't forget to delete the ${NAMESPACE} namespace !!! ========== "
