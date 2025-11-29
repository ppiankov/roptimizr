#!/bin/bash

# roptimizr.sh
# Scan Kubernetes pods, find "dying" or CPU-hot containers,
# and recommend updated CPU/memory requests/limits.
# Also:
# - Summarize total current vs suggested CPU/mem
# - Compare to cluster allocatable resources
# - Count pods with no resource limits set

# --- Config ------------------------------------------------------------------

scaling_factor=1.3        # how aggressively to scale vs real usage
verbose=0                 # set to 1 for noisy debug output
exclude_namespaces="kube-node-lease,kube-system"

# Kubeconfig handling:
# Option A (recommended): rely on env KUBECONFIG or current context
# Option B (for scared humans): set kubeconfig_path explicitly:
#   kubeconfig_path="/Users/you/.kube/cluster-config"
kubeconfig_path=""

# When is a pod "interesting" enough to look at?
CPU_HOT_THRESHOLD_PCT=80  # % of CPU limit usage to call it "hot"
RESTART_THRESHOLD=1       # restartCount >= this => dying/suspect

# Totals for capacity planning (current)
baseline_total_request_cpu_m=0
baseline_total_limit_cpu_m=0
baseline_total_request_mem_Mi=0
baseline_total_limit_mem_Mi=0

# Totals for deltas after applying recommendations
total_cpu_needed_request=0
total_mem_needed_request=0
total_cpu_needed_limit=0
total_mem_needed_limit=0

# Cluster-wide allocatable
cluster_allocatable_cpu_m=0
cluster_allocatable_mem_Mi=0

# Pods with no limits set on any container
pods_without_limits=0

# --- kubectl wrapper ---------------------------------------------------------

# Use an array so flags are handled safely
KCTL=(kubectl)
if [[ -n "$kubeconfig_path" ]]; then
  KCTL=(kubectl --kubeconfig="$kubeconfig_path")
fi

# --- Helpers -----------------------------------------------------------------

convert_cpu_to_millicores() {
  local value=$1

  if [[ -z "$value" ]]; then
    echo ""
    return
  fi

  if [[ "$value" == *m ]]; then
    echo "${value%m}"
  else
    awk -v v="$value" 'BEGIN {printf("%.0f\n", v * 1000)}'
  fi
}

convert_memory_to_Mi() {
  local value=$1

  if [[ -z "$value" ]]; then
    echo ""
    return
  fi

  if [[ "$value" == *Mi ]]; then
    echo "${value%Mi}"
  elif [[ "$value" == *Gi ]]; then
    awk -v v="${value%Gi}" 'BEGIN {printf("%.0f\n", v * 1024)}'
  elif [[ "$value" == *Ki ]]; then
    awk -v v="${value%Ki}" 'BEGIN {printf("%.0f\n", v / 1024)}'
  else
    echo "$value"
  fi
}

needs_fix() {
  local real=$1
  local value=$2
  local sf=$3
  local direction=$4

  if [[ -z "$real" || -z "$value" || -z "$sf" ]]; then
    echo 0
    return
  fi

  if [ "$direction" == "high" ]; then
    echo "$real $value $sf" | awk '{if ($1 * $3 < $2) print 1; else print 0;}'
  elif [ "$direction" == "low" ]; then
    echo "$real $value $sf" | awk '{if ($1 > $2 * $3 ) print 1; else print 0;}'
  else
    echo 0
  fi
}

apply_fix() {
  local namespace=$1
  local pod=$2
  local container=$3

  local cpulimit_millicores=$4
  local memlimit_Mi=$5
  local cpu_real_millicores=$6
  local mem_real_Mi=$7
  local cpurequest_millicores=$8
  local memrequest_Mi=$9

  local new_cpulimit
  local new_cpurequest
  local new_memlimit
  local new_memrequest

  new_cpulimit=$(awk -v cpu="$cpu_real_millicores" -v sf="$scaling_factor" 'BEGIN {printf("%.0f", cpu * sf * 1.3)}')
  new_cpurequest=$(awk -v cpu="$cpu_real_millicores" 'BEGIN {printf("%.0f", cpu)}')
  new_memlimit=$(awk -v mem="$mem_real_Mi" -v sf="$scaling_factor" 'BEGIN {printf("%.0f", mem * sf * 1.3)}')
  new_memrequest=$(awk -v mem="$mem_real_Mi" 'BEGIN {printf("%.0f", mem)}')

  [ "$new_cpulimit"    -lt 10 ] && new_cpulimit=10
  [ "$new_cpurequest"  -lt 10 ] && new_cpurequest=10
  [ "$new_memlimit"    -lt 10 ] && new_memlimit=10
  [ "$new_memrequest"  -lt 10 ] && new_memrequest=10

  if [ "$new_cpulimit" -eq "$new_cpurequest" ]; then
    new_cpulimit=$(awk -v cpu="$new_cpulimit" -v sf="$scaling_factor" 'BEGIN {printf("%.0f", cpu * sf * 1.3)}')
  fi

  if [ "$new_memlimit" -eq "$new_memrequest" ]; then
    new_memlimit=$(awk -v mem="$new_memlimit" -v sf="$scaling_factor" 'BEGIN {printf("%.0f", mem * sf * 1.3)}')
  fi

  total_cpu_needed_request=$((total_cpu_needed_request + new_cpurequest - cpurequest_millicores))
  total_mem_needed_request=$((total_mem_needed_request + new_memrequest - memrequest_Mi))

  total_cpu_needed_limit=$((total_cpu_needed_limit + new_cpulimit - cpulimit_millicores))
  total_mem_needed_limit=$((total_mem_needed_limit + new_memlimit - memlimit_Mi))

  # Recompute high/low flags for explanation text
  local cpu_limit_too_high cpu_request_too_high mem_limit_too_high mem_request_too_high
  local cpu_limit_too_low cpu_request_too_low mem_limit_too_low mem_request_too_low

  cpu_limit_too_high=$(needs_fix "$cpu_real_millicores" "$cpulimit_millicores" "$scaling_factor" "high")
  cpu_request_too_high=$(needs_fix "$cpu_real_millicores" "$cpurequest_millicores" "$scaling_factor" "high")
  mem_limit_too_high=$(needs_fix "$mem_real_Mi" "$memlimit_Mi" "$scaling_factor" "high")
  mem_request_too_high=$(needs_fix "$mem_real_Mi" "$memrequest_Mi" "$scaling_factor" "high")

  cpu_limit_too_low=$(needs_fix "$cpu_real_millicores" "$cpulimit_millicores" "$scaling_factor" "low")
  cpu_request_too_low=$(needs_fix "$cpu_real_millicores" "$cpurequest_millicores" "$scaling_factor" "low")
  mem_limit_too_low=$(needs_fix "$mem_real_Mi" "$memlimit_Mi" "$scaling_factor" "low")
  mem_request_too_low=$(needs_fix "$mem_real_Mi" "$memrequest_Mi" "$scaling_factor" "low")

  # Pretty, human-readable output
  echo "──────────────────────────────────────────────────────────────"
  echo "⚠️  Resource Optimization Suggestion"
  echo "Namespace:         $namespace"
  echo "Pod:               $pod"
  echo "Container:         $container"
  echo
  echo "Current Resources:"
  printf "  CPU:             request=%-7s limit=%-7s\n"  "${cpurequest_millicores}m" "${cpulimit_millicores}m"
  printf "  Memory:          request=%-7s limit=%-7s\n"  "${memrequest_Mi}Mi"        "${memlimit_Mi}Mi"
  echo
  echo "Observed Usage (pod-level):"
  printf "  CPU actual:      %-7s\n"  "${cpu_real_millicores}m"
  printf "  Memory actual:   %-7s\n"  "${mem_real_Mi}Mi"
  echo
  echo "Suggested New Resources:"
  printf "  CPU:             request=%-7s limit=%-7s\n"  "${new_cpurequest}m"  "${new_cpulimit}m"
  printf "  Memory:          request=%-7s limit=%-7s\n"  "${new_memrequest}Mi" "${new_memlimit}Mi"
  echo
  echo "Reason:"
  local printed_reason=0
  if [ "$cpu_limit_too_high" = "1" ] || [ "$cpu_request_too_high" = "1" ]; then
    echo "  • CPU allocation appears too high relative to observed usage"
    printed_reason=1
  fi
  if [ "$mem_limit_too_high" = "1" ] || [ "$mem_request_too_high" = "1" ]; then
    echo "  • Memory allocation appears too high relative to observed usage"
    printed_reason=1
  fi
  if [ "$cpu_limit_too_low" = "1" ] || [ "$cpu_request_too_low" = "1" ]; then
    echo "  • CPU resources might be too low for observed load"
    printed_reason=1
  fi
  if [ "$mem_limit_too_low" = "1" ] || [ "$mem_request_too_low" = "1" ]; then
    echo "  • Memory resources might be too low for observed load"
    printed_reason=1
  fi
  if [ "$printed_reason" -eq 0 ]; then
    echo "  • Resource settings differ noticeably from observed usage"
  fi
  echo "──────────────────────────────────────────────────────────────"
  echo
}

compute_cluster_capacity() {
  local node_names
  node_names=$("${KCTL[@]}" get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

  for node in $node_names; do
    local cpu mem cpu_m mem_Mi

    cpu=$("${KCTL[@]}" get node "$node" -o jsonpath='{.status.allocatable.cpu}' 2>/dev/null)
    mem=$("${KCTL[@]}" get node "$node" -o jsonpath='{.status.allocatable.memory}' 2>/dev/null)

    cpu_m=$(convert_cpu_to_millicores "$cpu")
    mem_Mi=$(convert_memory_to_Mi "$mem")

    [ -n "$cpu_m" ] && cluster_allocatable_cpu_m=$((cluster_allocatable_cpu_m + cpu_m))
    [ -n "$mem_Mi" ] && cluster_allocatable_mem_Mi=$((cluster_allocatable_mem_Mi + mem_Mi))
  done
}

# --- Main loop ---------------------------------------------------------------

namespaces=$("${KCTL[@]}" get namespaces --no-headers 2>/dev/null | awk '{print $1}' | grep -v -w -E "${exclude_namespaces//,/|}")

if [ "$verbose" -eq 1 ]; then
  echo "Namespaces:"
  echo "$namespaces"
fi

for namespace in $namespaces; do
  pods=$("${KCTL[@]}" get pod -n "$namespace" --no-headers 2>/dev/null | awk '{print $1}')

  for pod in $pods; do
    pod_has_no_limits=0

    if "${KCTL[@]}" get pod -n "$namespace" "$pod" -o jsonpath='{.metadata.annotations.forbid_rl_modification}' 2>/dev/null | grep -q "yes"; then
      [ "$verbose" -eq 1 ] && echo "Skipping $namespace/$pod due to forbid_rl_modification"
      continue
    fi

    top_line=$("${KCTL[@]}" top pod -n "$namespace" "$pod" 2>/dev/null | awk 'NR==2 {print $2, $3}')
    if [[ -z "$top_line" ]]; then
      [ "$verbose" -eq 1 ] && echo "No metrics for $namespace/$pod, skipping metrics-based logic"
      cpu_real_millicores=0
      mem_real_Mi=0
    else
      read -r cpu_real mem_real <<< "$top_line"
      cpu_real_millicores=$(convert_cpu_to_millicores "$cpu_real")
      mem_real_Mi=$(convert_memory_to_Mi "$mem_real")
      [ -z "$cpu_real_millicores" ] && cpu_real_millicores=0
      [ -z "$mem_real_Mi" ] && mem_real_Mi=0
    fi

    containers=$("${KCTL[@]}" get pod -n "$namespace" "$pod" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null)

    for container in $containers; do
      cpulimit=$("${KCTL[@]}" -n "$namespace" get pod "$pod" -o jsonpath="{.spec.containers[?(@.name=='$container')].resources.limits.cpu}")
      cpurequest=$("${KCTL[@]}" -n "$namespace" get pod "$pod" -o jsonpath="{.spec.containers[?(@.name=='$container')].resources.requests.cpu}")
      memlimit=$("${KCTL[@]}" -n "$namespace" get pod "$pod" -o jsonpath="{.spec.containers[?(@.name=='$container')].resources.limits.memory}")
      memrequest=$("${KCTL[@]}" -n "$namespace" get pod "$pod" -o jsonpath="{.spec.containers[?(@.name=='$container')].resources.requests.memory}")

      cpulimit_millicores=$(convert_cpu_to_millicores "$cpulimit")
      cpurequest_millicores=$(convert_cpu_to_millicores "$cpurequest")
      memlimit_Mi=$(convert_memory_to_Mi "$memlimit")
      memrequest_Mi=$(convert_memory_to_Mi "$memrequest")

      if [[ -z "$cpulimit" && -z "$memlimit" ]]; then
        pod_has_no_limits=1
      fi

      if [[ -n "$cpulimit_millicores" && -n "$cpurequest_millicores" && -n "$memlimit_Mi" && -n "$memrequest_Mi" ]]; then
        baseline_total_request_cpu_m=$((baseline_total_request_cpu_m + cpurequest_millicores))
        baseline_total_limit_cpu_m=$((baseline_total_limit_cpu_m + cpulimit_millicores))
        baseline_total_request_mem_Mi=$((baseline_total_request_mem_Mi + memrequest_Mi))
        baseline_total_limit_mem_Mi=$((baseline_total_limit_mem_Mi + memlimit_Mi))
      fi

      if [[ -z "$cpulimit_millicores" || -z "$cpurequest_millicores" || -z "$memlimit_Mi" || -z "$memrequest_Mi" ]]; then
        [ "$verbose" -eq 1 ] && echo "Missing RL for $namespace/$pod/$container, skipping optimization"
        continue
      fi

      restart_count=$("${KCTL[@]}" -n "$namespace" get pod "$pod" -o jsonpath="{.status.containerStatuses[?(@.name=='$container')].restartCount}")
      waiting_reason=$("${KCTL[@]}" -n "$namespace" get pod "$pod" -o jsonpath="{.status.containerStatuses[?(@.name=='$container')].state.waiting.reason}")

      [ -z "$restart_count" ] && restart_count=0

      is_restarting=0
      if [ "$restart_count" -ge "$RESTART_THRESHOLD" ] || [[ "$waiting_reason" == "CrashLoopBackOff" || "$waiting_reason" == "Error" ]]; then
        is_restarting=1
      fi

      is_cpu_hot=0
      if [ "$cpulimit_millicores" -gt 0 ] && [ "$cpu_real_millicores" -gt $((cpulimit_millicores * CPU_HOT_THRESHOLD_PCT / 100)) ]; then
        is_cpu_hot=1
      fi

      if [ "$is_restarting" -eq 0 ] && [ "$is_cpu_hot" -eq 0 ]; then
        [ "$verbose" -eq 1 ] && echo "Container $namespace/$pod/$container looks fine (restarts=$restart_count, cpu_hot=$is_cpu_hot)"
        continue
      fi

      cpu_limit_too_high=$(needs_fix "$cpu_real_millicores" "$cpulimit_millicores" "$scaling_factor" "high")
      cpu_request_too_high=$(needs_fix "$cpu_real_millicores" "$cpurequest_millicores" "$scaling_factor" "high")
      mem_limit_too_high=$(needs_fix "$mem_real_Mi" "$memlimit_Mi" "$scaling_factor" "high")
      mem_request_too_high=$(needs_fix "$memrequest_Mi" "$memrequest_Mi" "$scaling_factor" "high")

      cpu_limit_too_low=$(needs_fix "$cpu_real_millicores" "$cpulimit_millicores" "$scaling_factor" "low")
      cpu_request_too_low=$(needs_fix "$cpu_real_millicores" "$cpurequest_millicores" "$scaling_factor" "low")
      mem_limit_too_low=$(needs_fix "$mem_real_Mi" "$memlimit_Mi" "$scaling_factor" "low")
      mem_request_too_low=$(needs_fix "$mem_real_Mi" "$memrequest_Mi" "$scaling_factor" "low")

      # If anything looks off, propose a fix
      if [ "$cpu_limit_too_low" = "1" ] || [ "$cpu_request_too_low" = "1" ] || \
         [ "$mem_limit_too_low" = "1" ] || [ "$mem_request_too_low" = "1" ] || \
         [ "$cpu_limit_too_high" = "1" ] || [ "$cpu_request_too_high" = "1" ] || \
         [ "$mem_limit_too_high" = "1" ] || [ "$mem_request_too_high" = "1" ]; then

        apply_fix "$namespace" "$pod" "$container" \
          "$cpulimit_millicores" "$memlimit_Mi" \
          "$cpu_real_millicores" "$mem_real_Mi" \
          "$cpurequest_millicores" "$memrequest_Mi"
      fi

    done

    if [ "$pod_has_no_limits" -eq 1 ]; then
      pods_without_limits=$((pods_without_limits + 1))
    fi

  done
done

compute_cluster_capacity

new_total_request_cpu_m=$((baseline_total_request_cpu_m + total_cpu_needed_request))
new_total_limit_cpu_m=$((baseline_total_limit_cpu_m + total_cpu_needed_limit))
new_total_request_mem_Mi=$((baseline_total_request_mem_Mi + total_mem_needed_request))
new_total_limit_mem_Mi=$((baseline_total_limit_mem_Mi + total_mem_needed_limit))

echo
echo "===================== SUMMARY ====================="
echo "Pods with NO resource limits set: $pods_without_limits"
echo
echo "Current total requested CPU:  ${baseline_total_request_cpu_m}m"
echo "Current total limit CPU:      ${baseline_total_limit_cpu_m}m"
echo "After suggested changes, req: ${new_total_request_cpu_m}m"
echo "After suggested changes, lim: ${new_total_limit_cpu_m}m"
echo
echo "Current total requested Mem:  ${baseline_total_request_mem_Mi}Mi"
echo "Current total limit Mem:      ${baseline_total_limit_mem_Mi}Mi"
echo "After suggested changes, req: ${new_total_request_mem_Mi}Mi"
echo "After suggested changes, lim: ${new_total_limit_mem_Mi}Mi"
echo
echo "Cluster allocatable CPU:      ${cluster_allocatable_cpu_m}m"
echo "Cluster allocatable Mem:      ${cluster_allocatable_mem_Mi}Mi"
echo
if [ "$cluster_allocatable_cpu_m" -gt 0 ]; then
  cpu_req_pct=$((new_total_request_cpu_m * 100 / cluster_allocatable_cpu_m))
  cpu_lim_pct=$((new_total_limit_cpu_m * 100 / cluster_allocatable_cpu_m))
  echo "CPU after suggested changes:"
  echo "  Requests use ~${cpu_req_pct}% of allocatable"
  echo "  Limits   use ~${cpu_lim_pct}% of allocatable"
fi
if [ "$cluster_allocatable_mem_Mi" -gt 0 ]; then
  mem_req_pct=$((new_total_request_mem_Mi * 100 / cluster_allocatable_mem_Mi))
  mem_lim_pct=$((new_total_limit_mem_Mi * 100 / cluster_allocatable_mem_Mi))
  echo "Memory after suggested changes:"
  echo "  Requests use ~${mem_req_pct}% of allocatable"
  echo "  Limits   use ~${mem_lim_pct}% of allocatable"
fi
echo "==================================================="