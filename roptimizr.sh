#!/bin/bash

# Variables
scaling_factor=1.3
verbose=0
exclude_namespaces="kube-node-lease,kube-system"
total_cpu_needed=0
total_mem_needed=0
kubeconfig=""
#kubeconfig="--kubeconfig=/path/to/.kube/config"


# Function to convert CPU units to millicores
convert_cpu_to_millicores() {
  local value=$1
  if [[ $value == *m ]]; then
    echo "${value%m}"
  else
    echo $(( value * 1000 ))
  fi
}

# Function to convert memory units to Mi
convert_memory_to_Mi() {
  local value=$1
  if [[ $value == *Mi ]]; then
    echo "${value%Mi}"
  elif [[ $value == *Gi ]]; then
    echo $(( ${value%Gi} * 1024 ))
  else
    echo $value
  fi
}

# Function to check if the resource needs fixing
needs_fix() {
  local real=$1
  local value=$2
  local scaling_factor=$3
  local direction=$4
  if [ "$direction" == "high" ]; then
    echo "$real $value $scaling_factor" | awk '{if ( $1 * $3 < $2 ) print 1; else print 0;}'
  elif [ "$direction" == "low" ]; then
    echo "$real $value $scaling_factor" | awk '{if ( $1 > $2 * $3 ) print 1; else print 0;}'
  fi
}

apply_fix() {
  local namespace=$1
  local pod=$2
  local container=$3
  local cpulimit=$4
  local memlimit=$5
  local cpu_real=$6
  local mem_real=$7

  # Calculate new limits and requests

  local new_cpulimit=$(awk -v cpu="$cpu_real" -v sf="$scaling_factor" 'BEGIN {printf("%.0f", cpu * sf * 1.3)}')
  local new_cpurequest=$(awk -v cpu="$cpu_real" 'BEGIN {printf("%.0f", cpu)}')
  local new_memlimit=$(awk -v mem="$mem_real" -v sf="$scaling_factor" 'BEGIN {printf("%.0f", mem * sf * 1.3)}')
  local new_memrequest=$(awk -v mem="$mem_real" 'BEGIN {printf("%.0f", mem)}')

  if [ $new_cpulimit -lt 10 ]; then
     new_cpulimit=10
  fi
  if [ $new_cpurequest -lt 10 ]; then
     new_cpurequest=10
  fi
  if [ $new_memlimit -lt 10 ]; then
     new_memlimit=10
  fi

  if [ $new_memrequest -lt 10 ]; then
     new_memrequest=10
  fi

  if [ $new_cpulimit -eq $new_cpurequest ]; then
     new_cpulimit=$(awk -v mem="$new_cpulimit" -v sf="$scaling_factor" 'BEGIN {printf("%.0f", mem * sf * 1.3)}')
  fi

  if [ $new_memlimit -eq $new_memrequest ]; then
     new_memlimit=$(awk -v mem="$mem_real" -v sf="$new_memlimit" 'BEGIN {printf("%.0f", mem * sf * 1.3)}')
  fi
 


  # Update total_cpu_needed and total_mem_needed
  total_cpu_needed_request=$((total_cpu_needed + new_cpurequest - cpurequest_millicores))
  total_mem_needed_request=$((total_mem_needed + new_memrequest - memrequest_Mi))

  total_cpu_needed_limit=$((total_cpu_needed + new_cpulimit - cpulimit_millicores))
  total_mem_needed_limit=$((total_mem_needed + new_memlimit - memlimit_Mi))


  # uncomment if need to apply the changes
  # Apply changes to the deployment manifest
  # kubectl $kubeconfig -n "$namespace" patch pod "$pod" -p "$(cat <<EOF
  # spec:
  # containers:
  # - name: $container_name
  #     resources:
  #     limits:
  #         cpu: "${new_cpu_limit}m"
  #         memory: "${new_mem_limit}Mi"
  # EOF
  # )"
  #echo "Applied fix: $namespace/$pod/$container_name -> CPU: ${new_cpurequest}m/${new_cpulimit}m, Memory: ${new_memrequest}Mi/${new_memlimit}Mi"
  #echo "Applied fix: $namespace/$pod/$container_name -> CPU: ${new_cpu_limit}m, Memory: ${new_mem_limit}Mi"
  # }

  # Log the modifications
  #echo "Modified $namespace/$pod/$container"
  echo "Recommendation $namespace/$pod/$container"
  echo "  CPU: $cpurequest/$cpulimit => ${new_cpurequest}m/${new_cpulimit}m"
  echo "  Memory: $memrequest/$memlimit => ${new_memrequest}Mi/${new_memlimit}Mi"
}

for namespace in $(kubectl $kubeconfig get namespaces | tail -n +2 | awk '{print $1}' | grep -v -w -E "${exclude_namespaces//,/|}")
do
  for p in $(kubectl $kubeconfig get pod -n $namespace | grep Running | awk '{print $1}')
  do
    for container in $(kubectl $kubeconfig get pod -n $namespace $p -o jsonpath='{.spec.containers[*].name}')
    do
      if kubectl $kubeconfig get pod -n $namespace $p -o jsonpath='{.metadata.annotations.forbid_rl_modification}' | grep -q "yes"; then
        continue
      fi
      # Modify the loop where you fetch cpulimit, cpurequest, memlimit, and memrequest:
      cpulimit=$(kubectl $kubeconfig -n $namespace get pod $p -o jsonpath="{.spec.containers[?(@.name=='$container')].resources.limits.cpu}")
      cpurequest=$(kubectl $kubeconfig -n $namespace get pod $p -o jsonpath="{.spec.containers[?(@.name=='$container')].resources.requests.cpu}")
      memlimit=$(kubectl $kubeconfig -n $namespace get pod $p -o jsonpath="{.spec.containers[?(@.name=='$container')].resources.limits.memory}")
      memrequest=$(kubectl $kubeconfig -n $namespace get pod $p -o jsonpath="{.spec.containers[?(@.name=='$container')].resources.requests.memory}")

      cpulimit_millicores=$(convert_cpu_to_millicores "$cpulimit")
      cpurequest_millicores=$(convert_cpu_to_millicores "$cpurequest")
      memlimit_Mi=$(convert_memory_to_Mi "$memlimit")
      memrequest_Mi=$(convert_memory_to_Mi "$memrequest")
      #mem_go_real=$(curl --silent -G '//https://prometheus.company.com/api/v1/query' --data-urlencode 'query=sum(container_memory_working_set_bytes{job="kubelet", metrics_path="/metrics/cadvisor", cluster="", namespace="$namespace", pod="$p", container!="", image!=""}) by (container)' | jq -r '.data.result[].value[1]' | awk '{sum = $1 + $2; printf("%.4f\n", sum/1024/1024/1024)}')


      if [ -z "$cpulimit_millicores" ] || [ -z "$cpurequest_millicores" ] || [ -z "$memlimit_Mi" ] || [ -z "$memrequest_Mi" ]; then
        continue
      fi

      cpu_real=$(kubectl $kubeconfig top pod -n $namespace $p|grep $p|awk '{print $2}')
      mem_real=$(kubectl $kubeconfig top pod -n $namespace $p|grep $p|awk '{print $3}')

      #cpu_real=$(kubectl $kubeconfig top pod -n $namespace $p | tail -n +2 | grep $p | awk '{print $2}')
      #mem_real=$(kubectl $kubeconfig top pod -n $namespace $p | tail -n +2 | grep $p | awk '{print $3}')

      cpu_real_millicores=$(convert_cpu_to_millicores "$cpu_real")
      mem_real_Mi=$(convert_memory_to_Mi "$mem_real")

      cpu_needs_fix=0
      mem_needs_fix=0

      # Check for missing data and set to 0
      if [ -z "$cpu_real_millicores" ]; then
        cpu_real_millicores=0
      fi

      if [ -z "$mem_real_Mi" ]; then
        mem_real_Mi=0
      fi

      if [ -z "$mem_go_real" ]; then
        mem_go_real=0
      fi


      cpu_limit_too_high=$(needs_fix "$cpu_real_millicores" "$cpulimit_millicores" "$scaling_factor" "high")
      cpu_request_too_high=$(needs_fix "$cpu_real_millicores" "$cpurequest_millicores" "$scaling_factor" "high")
      mem_limit_too_high=$(needs_fix "$mem_real_Mi" "$memlimit_Mi" "$scaling_factor" "high")
      mem_request_too_high=$(needs_fix "$mem_real_Mi" "$memrequest_Mi" "$scaling_factor" "high")

      cpu_limit_too_low=$(needs_fix "$cpu_real_millicores" "$cpulimit_millicores" "$scaling_factor" "low")
      cpu_request_too_low=$(needs_fix "$cpu_real_millicores" "$cpurequest_millicores" "$scaling_factor" "low")
      mem_limit_too_low=$(needs_fix "$mem_real_Mi" "$memlimit_Mi" "$scaling_factor" "low")
      mem_request_too_low=$(needs_fix "$mem_real_Mi" "$memrequest_Mi" "$scaling_factor" "low")


      if [ "$verbose" -eq 1 ]; then
        echo "namespace: $namespace"
        echo "cpulimit: $cpulimit"
        echo "cpulimit_millicors: $cpulimit_millicores"
        echo "cpurequest: $cpurequest"
        echo "memlimit: $memlimit"
        echo "memlimit_Mi: $memlimit_Mi"
        echo "memrequest: $memrequest"
        echo "memrequest_Mi: $memrequest_Mi"
        echo "memlimit_Mi: $memlimit_Mi"
        echo "cpurequest_millicores: $cpurequest_millicores"
        echo "mem_go_real: $mem_go_real"
        echo "cpu_real: $cpu_real"
        echo "mem_real: $mem_real"
        echo "cpu_needs_fix: $cpu_needs_fix"
        echo "mem_needs_fix: $mem_needs_fix"
      fi


      if [ "$cpu_limit_too_low" = "1" ] || [ "$cpu_request_too_low" = "1" ] || [ "$mem_limit_too_low" = "1" ] || [ "$mem_request_too_low" = "1" ] || [ "$cpu_limit_too_high" = "1" ] || [ "$cpu_request_too_high" = "1" ] || [ "$mem_limit_too_high" = "1" ] || [ "$mem_request_too_high" = "1" ]; then
        apply_fix "$namespace" "$p" "$container" "$cpulimit_millicores" "$memlimit_Mi" "$cpu_real_millicores" "$mem_real_Mi"
      fi

    done
  done
done

echo "Total request millicores needed to apply the patches: $total_cpu_needed_request"
echo "Total request Mi needed to apply the patches: $total_mem_needed_request"
echo "Total limit millicores needed to apply the patches: $total_cpu_needed_limit"
echo "Total limit Mi needed to apply the patches: $total_mem_needed_limit"

