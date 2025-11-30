#!/bin/bash

# roptimizr.sh
# Kubernetes pod resource optimizer:
# - detects CPU-hot, memory-heavy, restarting, OOMKilled pods
# - computes suggested CPU/memory requests & limits
# - prints human-readable recommendations
# - summarizes cluster resource usage
# - highlights nodes overloaded with nodeAffinity-pinned pods
# - optionally hides low-usage pods with no explicit resources

scaling_factor=1.3
verbose=0
exclude_namespaces="kube-system,kube-node-lease"

# Aggressive mode (for LLM / bursty workloads)
aggressive=0
if [[ "$1" == "--aggressive" ]]; then
  aggressive=1
  shift
fi

# Report low-usage pods running with unset resources?
report_unset_lowusage=0
if [[ "$1" == "--report-unset-lowusage" ]]; then
  report_unset_lowusage=1
  shift
fi

# kubeconfig (empty uses current context or $KUBECONFIG)
kubeconfig=""
[ -n "$KUBECONFIG" ] && kubeconfig="--kubeconfig=$KUBECONFIG"

CPU_HOT_THRESHOLD_PCT=80
RESTART_THRESHOLD=1

baseline_total_request_cpu_m=0
baseline_total_limit_cpu_m=0
baseline_total_request_mem_Mi=0
baseline_total_limit_mem_Mi=0

total_cpu_needed_request=0
total_mem_needed_request=0
total_cpu_needed_limit=0
total_mem_needed_limit=0

cluster_allocatable_cpu_m=0
cluster_allocatable_mem_Mi=0

pods_without_limits=0

# Temp files for node / affinity tracking (portable)
tmp_all_nodes=$(mktemp /tmp/ropt_all_nodes.XXXXXX)
tmp_aff_nodes=$(mktemp /tmp/ropt_aff_nodes.XXXXXX)
trap 'rm -f -- "$tmp_all_nodes" "$tmp_aff_nodes"' EXIT

convert_cpu_to_millicores() {
  local v=$1
  [[ -z "$v" ]] && { echo ""; return; }
  [[ "$v" == *m ]] && { echo "${v%m}"; return; }
  awk -v x="$v" 'BEGIN{printf("%.0f", x*1000)}'
}

convert_memory_to_Mi() {
  local v=$1
  [[ -z "$v" ]] && { echo ""; return; }
  if [[ "$v" == *Mi ]]; then
    echo "${v%Mi}"
  elif [[ "$v" == *Gi ]]; then
    awk -v x="${v%Gi}" 'BEGIN{printf("%.0f", x*1024)}'
  elif [[ "$v" == *Ki ]]; then
    awk -v x="${v%Ki}" 'BEGIN{printf("%.0f", x/1024)}'
  else
    echo "$v"
  fi
}

apply_fix() {
  local ns=$1 pod=$2 ctr=$3
  local lim_cpu=$4 lim_mem=$5 real_cpu=$6 real_mem=$7 req_cpu=$8 req_mem=$9
  local is_oom=${10}

  local new_req_cpu new_lim_cpu
  local new_req_mem new_lim_mem

  # CPU — usage-based
  new_req_cpu=$real_cpu
  new_lim_cpu=$(awk -v x="$real_cpu" -v s="$scaling_factor" 'BEGIN{printf("%.0f", x*s*1.3)}')
  [[ $new_req_cpu -lt 10 ]] && new_req_cpu=10
  [[ $new_lim_cpu -lt 10 ]] && new_lim_cpu=10

  # MEMORY — OOMKill-aware
  if [[ "$is_oom" -eq 1 ]]; then
    if [[ $aggressive -eq 1 ]]; then
      new_lim_mem=$(( lim_mem * 3 ))
      [[ $new_lim_mem -lt $((lim_mem + 1024)) ]] && new_lim_mem=$((lim_mem + 1024))
      new_req_mem=$(( new_lim_mem * 80 / 100 ))
    else
      new_lim_mem=$(( lim_mem * 2 ))
      [[ $new_lim_mem -lt $((lim_mem + 256)) ]] && new_lim_mem=$((lim_mem + 256))
      new_req_mem=$(( new_lim_mem * 70 / 100 ))
    fi
  else
    new_req_mem=$real_mem
    new_lim_mem=$(awk -v x="$real_mem" -v s="$scaling_factor" 'BEGIN{printf("%.0f", x*s*1.3)}')
  fi

  [[ $new_req_mem -lt 10 ]] && new_req_mem=10
  [[ $new_lim_mem -lt 10 ]] && new_lim_mem=10

  total_cpu_needed_request=$((total_cpu_needed_request + new_req_cpu - req_cpu))
  total_mem_needed_request=$((total_mem_needed_request + new_req_mem - req_mem))
  total_cpu_needed_limit=$((total_cpu_needed_limit + new_lim_cpu - lim_cpu))
  total_mem_needed_limit=$((total_mem_needed_limit + new_lim_mem - lim_mem))

  echo
  echo "──────────────────────────────────────────────────────────────"
  echo "⚠️  Resource Optimization Suggestion"
  printf "Namespace:         %s\n" "$ns"
  printf "Pod:               %s\n" "$pod"
  printf "Container:         %s\n\n" "$ctr"

  echo "Current Resources:"
  printf "  CPU:             request=%-7s limit=%-7s\n" "${req_cpu}m" "${lim_cpu}m"
  printf "  Memory:          request=%-7s limit=%-7s\n\n" "${req_mem}Mi" "${lim_mem}Mi"

  echo "Observed Usage:"
  printf "  CPU actual:      %-7s\n" "${real_cpu}m"
  printf "  Memory actual:   %-7s\n\n" "${real_mem}Mi"

  echo "Suggested New Resources:"
  printf "  CPU:             request=%-7s limit=%-7s\n" "${new_req_cpu}m" "${new_lim_cpu}m"
  printf "  Memory:          request=%-7s limit=%-7s\n" "${new_req_mem}Mi" "${new_lim_mem}Mi"
  echo

  echo "Reason:"
  if [[ "$is_oom" -eq 1 ]]; then
    if [[ $aggressive -eq 1 ]]; then
      echo "  • Container suffered OOMKills — metrics unreliable"
      echo "  • Aggressive mode: tripled memory limit with safe minimum"
    else
      echo "  • Container suffered OOMKills — metrics unreliable"
      echo "  • Doubled memory limit with safe minimum"
    fi
  else
    echo "  • Resource usage significantly differs from allocations"
  fi

  echo "──────────────────────────────────────────────────────────────"
}

compute_cluster_capacity() {
  local nodes
  nodes=$(kubectl $kubeconfig get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null)
  for n in $nodes; do
    cpu=$(kubectl $kubeconfig get node "$n" -o jsonpath='{.status.allocatable.cpu}' 2>/dev/null)
    mem=$(kubectl $kubeconfig get node "$n" -o jsonpath='{.status.allocatable.memory}' 2>/dev/null)
    cpu_m=$(convert_cpu_to_millicores "$cpu")
    mem_Mi=$(convert_memory_to_Mi "$mem")
    cluster_allocatable_cpu_m=$((cluster_allocatable_cpu_m + cpu_m))
    cluster_allocatable_mem_Mi=$((cluster_allocatable_mem_Mi + mem_Mi))
  done
}

# MAIN LOOP -----------------------------------------------------

namespaces=$(kubectl $kubeconfig get namespaces --no-headers | awk '{print $1}' | grep -v -E "${exclude_namespaces//,/|}")

for ns in $namespaces; do
  pods=$(kubectl $kubeconfig get pods -n "$ns" --no-headers | awk '{print $1}')

  for pod in $pods; do
    pod_has_no_limits=0

    node_name=$(kubectl $kubeconfig -n "$ns" get pod "$pod" -o jsonpath='{.spec.nodeName}')
    [[ -n "$node_name" ]] && echo "$node_name" >> "$tmp_all_nodes"

    node_affinity=$(kubectl $kubeconfig -n "$ns" get pod "$pod" -o jsonpath='{.spec.affinity.nodeAffinity}')
    if [[ -n "$node_affinity" && -n "$node_name" ]]; then
      echo "$node_name" >> "$tmp_aff_nodes"
    fi

    top_line=$(kubectl $kubeconfig top pod -n "$ns" "$pod" 2>/dev/null | awk 'NR==2{print $2, $3}')
    if [[ -n "$top_line" ]]; then
      read -r cpu_real mem_real <<< "$top_line"
      cpu_real=$(convert_cpu_to_millicores "$cpu_real")
      mem_real=$(convert_memory_to_Mi "$mem_real")
    else
      cpu_real=0
      mem_real=0
    fi

    containers=$(kubectl $kubeconfig get pod -n "$ns" "$pod" -o jsonpath='{.spec.containers[*].name}')

    for ctr in $containers; do

      lim_cpu=$(kubectl $kubeconfig -n "$ns" get pod "$pod" -o jsonpath="{.spec.containers[?(@.name=='$ctr')].resources.limits.cpu}")
      lim_mem=$(kubectl $kubeconfig -n "$ns" get pod "$pod" -o jsonpath="{.spec.containers[?(@.name=='$ctr')].resources.limits.memory}")
      req_cpu=$(kubectl $kubeconfig -n "$ns" get pod "$pod" -o jsonpath="{.spec.containers[?(@.name=='$ctr')].resources.requests.cpu}")
      req_mem=$(kubectl $kubeconfig -n "$ns" get pod "$pod" -o jsonpath="{.spec.containers[?(@.name=='$ctr')].resources.requests.memory}")

      lim_cpu_m=$(convert_cpu_to_millicores "$lim_cpu")
      lim_mem_Mi=$(convert_memory_to_Mi "$lim_mem")
      req_cpu_m=$(convert_cpu_to_millicores "$req_cpu")
      req_mem_Mi=$(convert_memory_to_Mi "$req_mem")

      if [[ -z "$lim_cpu" && -z "$lim_mem" ]]; then
        pod_has_no_limits=1
      fi

      baseline_total_request_cpu_m=$((baseline_total_request_cpu_m + req_cpu_m))
      baseline_total_limit_cpu_m=$((baseline_total_limit_cpu_m + lim_cpu_m))
      baseline_total_request_mem_Mi=$((baseline_total_request_mem_Mi + req_mem_Mi))
      baseline_total_limit_mem_Mi=$((baseline_total_limit_mem_Mi + lim_mem_Mi))

      restart_count=$(kubectl $kubeconfig -n "$ns" get pod "$pod" -o jsonpath="{.status.containerStatuses[?(@.name=='$ctr')].restartCount}")
      waiting_reason=$(kubectl $kubeconfig -n "$ns" get pod "$pod" -o jsonpath="{.status.containerStatuses[?(@.name=='$ctr')].state.waiting.reason}")
      oom_reason=$(kubectl $kubeconfig -n "$ns" get pod "$pod" -o jsonpath="{.status.containerStatuses[?(@.name=='$ctr')].lastState.terminated.reason}")

      [[ -z "$restart_count" ]] && restart_count=0

      is_restarting=0
      [[ $restart_count -ge $RESTART_THRESHOLD ]] && is_restarting=1
      [[ "$waiting_reason" == "CrashLoopBackOff" || "$waiting_reason" == "Error" ]] && is_restarting=1

      is_oomkilled=0
      [[ "$oom_reason" == "OOMKilled" ]] && is_oomkilled=1

      is_cpu_hot=0
      if [[ $lim_cpu_m -gt 0 ]] && [[ $cpu_real -gt $((lim_cpu_m * CPU_HOT_THRESHOLD_PCT / 100)) ]]; then
        is_cpu_hot=1
      fi

      # NEW: Skip unset low-usage pods unless explicitly reported
      if [[ $report_unset_lowusage -eq 0 ]]; then
        if [[ -z "$lim_cpu" && -z "$lim_mem" && -z "$req_cpu" && -z "$req_mem" ]]; then
          if (( cpu_real < 20 && mem_real < 50 )) && (( is_restarting == 0 && is_cpu_hot == 0 && is_oomkilled == 0 )); then
            continue
          fi
        fi
      fi

      # Skip pods with nothing interesting happening
      if [[ $is_restarting -eq 0 && $is_cpu_hot -eq 0 && $is_oomkilled -eq 0 ]]; then
        continue
      fi

      apply_fix "$ns" "$pod" "$ctr" \
        "$lim_cpu_m" "$lim_mem_Mi" \
        "$cpu_real" "$mem_real" \
        "$req_cpu_m" "$req_mem_Mi" \
        "$is_oomkilled"
    done

    [[ $pod_has_no_limits -eq 1 ]] && pods_without_limits=$((pods_without_limits + 1))
  done
done

compute_cluster_capacity

echo
echo "===================== SUMMARY ====================="
echo "Pods with NO resource limits set: $pods_without_limits"
echo
echo "Current total requested CPU:  ${baseline_total_request_cpu_m}m"
echo "Current total limit CPU:      ${baseline_total_limit_cpu_m}m"
echo "After suggested changes, req: $((baseline_total_request_cpu_m + total_cpu_needed_request))m"
echo "After suggested changes, lim: $((baseline_total_limit_cpu_m + total_cpu_needed_limit))m"
echo
echo "Current total requested Mem:  ${baseline_total_request_mem_Mi}Mi"
echo "Current total limit Mem:      ${baseline_total_limit_mem_Mi}Mi"
echo "After suggested changes, req: $((baseline_total_request_mem_Mi + total_mem_needed_request))Mi"
echo "After suggested changes, lim: $((baseline_total_limit_mem_Mi + total_mem_needed_limit))Mi"
echo
echo "Cluster allocatable CPU:      ${cluster_allocatable_cpu_m}m"
echo "Cluster allocatable Mem:      ${cluster_allocatable_mem_Mi}Mi"
echo "==================================================="

echo
echo "============= NODE AFFINITY CHECK ============="

has_hotspot=0

if [[ -s "$tmp_all_nodes" ]]; then
  while read -r count node; do
    total=$count
    with_affinity=$(grep -w "$node" "$tmp_aff_nodes" 2>/dev/null | wc -l | tr -d ' ')

    (( total == 0 )) && continue

    pct=$(( with_affinity * 100 / total ))

    if (( with_affinity >= 5 && pct >= 70 )); then
      has_hotspot=1
      echo "⚠️  Node: $node"
      echo "    • Pods on node:      $total"
      echo "    • With nodeAffinity: $with_affinity (${pct}%)"
      echo "    • Hint: A large share of workloads here are hard-pinned via nodeAffinity."
      echo "      Consider relaxing affinity / adding anti-affinity or spreading across more nodes."
      echo
    fi
  done < <(sort "$tmp_all_nodes" | uniq -c)
fi

if (( has_hotspot == 0 )); then
  echo "No obvious nodeAffinity hotspots detected."
fi

echo "==============================================="
