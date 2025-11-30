#!/bin/bash

# roptimizr.sh
# Kubernetes pod resource optimizer:
# - detects CPU-hot, memory-heavy, restarting, OOMKilled pods
# - computes suggested CPU/memory requests & limits
# - prints human-readable recommendations
# - summarizes cluster resource usage
# - highlights nodes overloaded with nodeAffinity-pinned pods

scaling_factor=1.3
verbose=0
exclude_namespaces="kube-system,kube-node-lease"

# Aggressive mode (for LLM / bursty workloads)
aggressive=0
if [[ "$1" == "--aggressive" ]]; then
  aggressive=1
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

# Temp files for node / affinity tracking (portable instead of bash associative arrays)
tmp_all_nodes=$(mktemp /tmp/roptimizr_all_nodes.XXXXXX)
tmp_aff_nodes=$(mktemp /tmp/roptimizr_aff_nodes.XXXXXX)

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

needs_fix() {
  local real=$1 val=$2 sf=$3 dir=$4
  [[ -z "$real" || -z "$val" ]] && { echo 0; return; }

  if [[ "$dir" == "high" ]]; then
    echo "$real $val $sf" | awk '{print ($1*$3 < $2)?1:0}'
  else
    echo "$real $val $sf" | awk '{print ($1 > $2*$3)?1:0}'
  fi
}

apply_fix() {
  local ns=$1 pod=$2 ctr=$3
  local lim_cpu=$4 lim_mem=$5 real_cpu=$6 real_mem=$7 req_cpu=$8 req_mem=$9
  local is_oom=${10}

  local new_req_cpu new_lim_cpu
  local new_req_mem new_lim_mem

  # CPU — usage-based (CPU spikes are actually sampled properly)
  new_req_cpu=$real_cpu
  new_lim_cpu=$(awk -v x="$real_cpu" -v s="$scaling_factor" 'BEGIN{printf("%.0f", x*s*1.3)}')
  [[ $new_req_cpu -lt 10 ]] && new_req_cpu=10
  [[ $new_lim_cpu -lt 10 ]] && new_lim_cpu=10

  # MEMORY — OOMKill-aware
  if [[ "$is_oom" -eq 1 ]]; then
    if [[ $aggressive -eq 1 ]]; then
      # 🚀 Aggressive mode (LLM / bursty workloads)
      new_lim_mem=$(( lim_mem * 3 ))
      # ensure at least +1Gi bump
      [[ $new_lim_mem -lt $((lim_mem + 1024)) ]] && new_lim_mem=$((lim_mem + 1024))
      new_req_mem=$(( new_lim_mem * 80 / 100 ))
    else
      # Standard OOMKill handling
      new_lim_mem=$(( lim_mem * 2 ))
      # ensure at least +256Mi bump
      [[ $new_lim_mem -lt $((lim_mem + 256)) ]] && new_lim_mem=$((lim_mem + 256))
      new_req_mem=$(( new_lim_mem * 70 / 100 ))
    fi
  else
    # Normal usage-based calculation
    new_req_mem=$real_mem
    new_lim_mem=$(awk -v x="$real_mem" -v s="$scaling_factor" 'BEGIN{printf("%.0f", x*s*1.3)}')
  fi

  # Enforce minimums
  [[ $new_req_mem -lt 10 ]] && new_req_mem=10
  [[ $new_lim_mem -lt 10 ]] && new_lim_mem=10

  # Update totals
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
      echo "  • Container suffered OOMKills → usage metrics unreliable"
      echo "  • Aggressive mode: tripled memory limit with safety floor, increased request"
    else
      echo "  • Container suffered OOMKills → usage metrics unreliable"
      echo "  • Applied safety rule: doubled memory limit with safety floor, increased request"
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

namespaces=$(kubectl $kubeconfig get namespaces --no-headers 2>/dev/null \
  | awk '{print $1}' \
  | grep -v -E "${exclude_namespaces//,/|}")

if [[ $verbose -eq 1 ]]; then
  echo "Namespaces:"
  echo "$namespaces"
fi

for ns in $namespaces; do
  pods=$(kubectl $kubeconfig get pods -n "$ns" --no-headers 2>/dev/null | awk '{print $1}')

  for pod in $pods; do
    pod_has_no_limits=0

    # Which node is this pod on?
    node_name=$(kubectl $kubeconfig -n "$ns" get pod "$pod" -o jsonpath='{.spec.nodeName}' 2>/dev/null)

    # Record nodes for counting later
    if [[ -n "$node_name" ]]; then
      echo "$node_name" >> "$tmp_all_nodes"
    fi

    # Does this pod have nodeAffinity configured?
    node_affinity=$(kubectl $kubeconfig -n "$ns" get pod "$pod" \
      -o jsonpath='{.spec.affinity.nodeAffinity}' 2>/dev/null)

    if [[ -n "$node_name" && -n "$node_affinity" ]]; then
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

    containers=$(kubectl $kubeconfig get pod -n "$ns" "$pod" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null)

    for ctr in $containers; do
      lim_cpu=$(kubectl $kubeconfig -n "$ns" get pod "$pod" \
        -o jsonpath="{.spec.containers[?(@.name=='$ctr')].resources.limits.cpu}")
      lim_mem=$(kubectl $kubeconfig -n "$ns" get pod "$pod" \
        -o jsonpath="{.spec.containers[?(@.name=='$ctr')].resources.limits.memory}")
      req_cpu=$(kubectl $kubeconfig -n "$ns" get pod "$pod" \
        -o jsonpath="{.spec.containers[?(@.name=='$ctr')].resources.requests.cpu}")
      req_mem=$(kubectl $kubeconfig -n "$ns" get pod "$pod" \
        -o jsonpath="{.spec.containers[?(@.name=='$ctr')].resources.requests.memory}")

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

      restart_count=$(kubectl $kubeconfig -n "$ns" get pod "$pod" \
        -o jsonpath="{.status.containerStatuses[?(@.name=='$ctr')].restartCount}" 2>/dev/null)
      waiting_reason=$(kubectl $kubeconfig -n "$ns" get pod "$pod" \
        -o jsonpath="{.status.containerStatuses[?(@.name=='$ctr')].state.waiting.reason}" 2>/dev/null)
      oom_reason=$(kubectl $kubeconfig -n "$ns" get pod "$pod" \
        -o jsonpath="{.status.containerStatuses[?(@.name=='$ctr')].lastState.terminated.reason}" 2>/dev/null)

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

      if [[ $verbose -eq 1 ]]; then
        echo "[DEBUG] ns=$ns pod=$pod ctr=$ctr restarts=$restart_count cpu_real=${cpu_real}m mem_real=${mem_real}Mi oom=$is_oomkilled cpu_hot=$is_cpu_hot"
      fi

      # Skip boring containers
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
  # sort + uniq -c gives: "<count> <nodeName>"
  while read -r count node; do
    total=$count
    # how many times this node appears in affinity list
    with_affinity=$(grep -w "$node" "$tmp_aff_nodes" 2>/dev/null | wc -l | tr -d ' ')

    (( total == 0 )) && continue

    pct=$(( with_affinity * 100 / total ))

    # Heuristic: more than 70% of pods on this node use nodeAffinity
    # and at least 5 such pods → likely over-pinning
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
  echo "No obvious nodeAffinity hotspots detected (nothing looks massively over-pinned to a single node)."
fi
echo "==============================================="

# Clean up temp files so we don't litter /tmp like animals
rm -f "$tmp_all_nodes" "$tmp_aff_nodes"