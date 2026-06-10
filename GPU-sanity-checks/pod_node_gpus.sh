#!/usr/bin/env bash
# Prints pods with GPU assignments and per-GPU health: temperature, clock, throttle status.
# Reads kubelet device-plugin checkpoint (via nvidia-device-plugin pods) for true indices.
# Usage: ./pod_node_gpus.sh [namespace]   (default: all namespaces)

NAMESPACE="${1:-}"
GPU_NS="nvidia-gpu-operator"
CHECKPOINT="/var/lib/kubelet/device-plugins/kubelet_internal_checkpoint"

MAX_CLOCK=1980
TEMP_AT_RISK=65
TEMP_WARN_IDLE=45

ns_flag="${NAMESPACE:+-n $NAMESPACE}"
[[ -z "$NAMESPACE" ]] && ns_flag="--all-namespaces"

is_throttled() {
  local reason_dec
  reason_dec=$(printf '%d' "$1" 2>/dev/null || echo 0)
  (( reason_dec >= 0x60 ))
}

gpu_status() {
  local temp="$1" clock_val="$2" reason="$3"
  if is_throttled "$reason"; then
    echo "THROTTLED ($reason)"
  elif (( clock_val < 1000 )); then
    (( temp >= TEMP_WARN_IDLE )) && echo "idle (WARM ${temp}C)" || echo "idle"
  elif (( clock_val < MAX_CLOCK )); then
    local pct=$(( clock_val * 100 / MAX_CLOCK ))
    (( temp >= TEMP_AT_RISK )) \
      && echo "AT RISK ${temp}C (${pct}% clock)" \
      || echo "throttled (thermal) ${pct}% clock"
  else
    echo "ok"
  fi
}

# Build node -> nvidia-device-plugin pod map (checkpoint access)
declare -A NODE_PLUGIN
while read -r plugin_pod node; do
  NODE_PLUGIN["$node"]="$plugin_pod"
done < <(kubectl get pods -n "$GPU_NS" -l app=nvidia-device-plugin-daemonset \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}')

# Build node -> dcgm pod map (nvidia-smi access)
declare -A NODE_DCGM
while read -r dcgm_pod node; do
  NODE_DCGM["$node"]="$dcgm_pod"
done < <(kubectl get pods -n "$GPU_NS" -l app=nvidia-dcgm \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}')

CACHE=$(mktemp -d)
trap 'rm -rf "$CACHE"' EXIT

# UUID -> physical index (cached per node)
uuid_to_index() {
  local node="$1" uuid="$2"
  local mapfile="$CACHE/smi_$node"
  if [[ ! -f "$mapfile" ]]; then
    local pod="${NODE_DCGM[$node]}"
    [[ -n "$pod" ]] && kubectl exec -n "$GPU_NS" "$pod" -- \
      nvidia-smi --query-gpu=index,uuid --format=csv,noheader 2>/dev/null \
      | tr -d ' ' > "$mapfile" || touch "$mapfile"
  fi
  awk -F',' -v u="$uuid" '$2==u {print $1}' "$mapfile"
}

# GPU stats (temp, clock, throttle) for an index on a node (cached per node)
gpu_stats_for_index() {
  local node="$1" idx="$2"
  local statsfile="$CACHE/stats_$node"
  if [[ ! -f "$statsfile" ]]; then
    local pod="${NODE_DCGM[$node]}"
    [[ -n "$pod" ]] && kubectl exec -n "$GPU_NS" "$pod" -- \
      nvidia-smi --query-gpu=index,temperature.gpu,clocks.sm,clocks_throttle_reasons.active \
      --format=csv,noheader 2>/dev/null | tr -d ' ' > "$statsfile" || touch "$statsfile"
  fi
  awk -F',' -v i="$idx" '$1==i {print $2","$3","$4}' "$statsfile"
}

# GPU UUIDs assigned to a pod from the kubelet checkpoint (cached per node)
get_pod_uuids() {
  local node="$1" pod_uid="$2" container="$3"
  local ckfile="$CACHE/ck_$node"
  if [[ ! -f "$ckfile" ]]; then
    local pod="${NODE_PLUGIN[$node]}"
    [[ -n "$pod" ]] && kubectl exec -n "$GPU_NS" "$pod" -- \
      cat "$CHECKPOINT" 2>/dev/null > "$ckfile" || touch "$ckfile"
  fi
  [[ ! -s "$ckfile" ]] && return
  jq -r --arg uid "$pod_uid" --arg c "$container" '
    .Data.PodDeviceEntries[] |
    select(.PodUID==$uid and .ContainerName==$c and .ResourceName=="nvidia.com/gpu") |
    .DeviceIDs | to_entries[] | .value[]' "$ckfile" 2>/dev/null
}

pod_data=$(kubectl get pods $ns_flag -o json | jq -r '
  .items[] |
  . as $pod |
  .spec.containers[] |
  . as $c |
  .resources.limits["nvidia.com/gpu"] // empty |
  "\($pod.metadata.namespace) \($pod.metadata.name) \($pod.metadata.uid) \($pod.spec.nodeName) \(.) \($c.name)"
')

[[ -z "$pod_data" ]] && { echo "No GPU pods found"; exit 0; }

printf "%-48s %-5s %-24s %-9s %-12s %s\n" "Pod" "GPU" "Node" "Temp(C)" "Clock(MHz)" "Status"
printf "%-48s %-5s %-24s %-9s %-12s %s\n" "---" "---" "----" "-------" "----------" "------"

while read -r pod_ns pod_name pod_uid pod_node gpus container; do
  mapfile -t uuids < <(get_pod_uuids "$pod_node" "$pod_uid" "$container")

  if [[ ${#uuids[@]} -gt 0 ]]; then
    for uuid in "${uuids[@]}"; do
      idx=$(uuid_to_index "$pod_node" "$uuid")
      stats=$(gpu_stats_for_index "$pod_node" "$idx")
      if [[ -n "$stats" ]]; then
        IFS=',' read -r temp clock reason <<< "$stats"
        clock_val="${clock%MHz}"
        status=$(gpu_status "$temp" "$clock_val" "$reason")
        printf "%-48s %-5s %-24s %-9s %-12s %s\n" "$pod_name" "$idx" "$pod_node" "$temp" "$clock_val" "$status"
      else
        printf "%-48s %-5s %-24s\n" "$pod_name" "$idx" "$pod_node"
      fi
    done
  else
    # checkpoint not accessible — print one row with no GPU detail
    printf "%-48s %-5s %-24s %s\n" "$pod_name" "?" "$pod_node" "(checkpoint unavailable)"
  fi
done <<< "$pod_data"
