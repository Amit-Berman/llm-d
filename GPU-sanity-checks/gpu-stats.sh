#!/usr/bin/env bash
# Prints per-node GPU temperature, SM clock, and throttle status.
# Uses nvidia-smi via nvidia-dcgm pods (one per GPU node).
# Throttle reasons: 0x0 = none, 0x1 = idle, 0x60+ = thermal/power throttle.

NAMESPACE="nvidia-gpu-operator"

# Max SM clock for this GPU family (MHz); used to detect thermal clock reduction
MAX_CLOCK=1980

# Temperature thresholds (Celsius)
TEMP_AT_RISK=65      # active at this temp or above: clock reduction likely to worsen
TEMP_WARN_IDLE=45    # idle at this temp or above: unexpectedly warm

# Throttle bitmask: 0x60 and above indicate HW/SW thermal or power throttle
is_throttled() {
  local reason_hex="$1"
  local reason_dec
  reason_dec=$(printf '%d' "$reason_hex" 2>/dev/null || echo 0)
  (( reason_dec >= 0x60 ))
}

# Collect nodes that are cordoned (unschedulable) in Kubernetes
declare -A DISABLED_NODES
while read -r node; do
  DISABLED_NODES["$node"]=1
done < <(kubectl get nodes --no-headers | awk '/SchedulingDisabled/ {print $1}')

printf "%-22s %-5s %-9s %-12s %s\n" "Node" "GPU" "Temp(C)" "Clock(MHz)" "Status"
printf "%-22s %-5s %-9s %-12s %s\n" "----" "---" "-------" "----------" "------"

kubectl get pods -n "$NAMESPACE" -l app=nvidia-dcgm \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}' \
| sort -k2 \
| while read -r pod node; do
    cordoned=""
    [[ -n "${DISABLED_NODES[$node]}" ]] && cordoned=" [cordoned]"

    output=$(kubectl exec -n "$NAMESPACE" "$pod" -- \
      nvidia-smi --query-gpu=index,temperature.gpu,clocks.sm,clocks_throttle_reasons.active \
      --format=csv,noheader 2>/dev/null || echo "ERROR")

    if [[ "$output" == "ERROR" ]]; then
      printf "%-22s  [nvidia-smi failed]\n" "$node"
      continue
    fi

    while IFS=', ' read -r gpu temp clock reason; do
      clock_val="${clock% MHz}"
      if is_throttled "$reason"; then
        status="THROTTLED ($reason)"
      elif [[ "$clock_val" =~ ^[0-9]+$ ]] && (( clock_val < 1000 )); then
        # idle — check if unexpectedly warm
        if [[ "$temp" =~ ^[0-9]+$ ]] && (( temp >= TEMP_WARN_IDLE )); then
          status="idle (WARM ${temp}C)"
        else
          status="idle (low clock)"
        fi
      elif [[ "$clock_val" =~ ^[0-9]+$ ]] && (( clock_val < MAX_CLOCK )); then
        # active but clock reduced — thermal throttling
        pct=$(( clock_val * 100 / MAX_CLOCK ))
        if [[ "$temp" =~ ^[0-9]+$ ]] && (( temp >= TEMP_AT_RISK )); then
          status="AT RISK ${temp}C throttled (${pct}% clock)"
        else
          status="throttled (thermal) ${pct}% clock"
        fi
      else
        status="ok"
      fi
      printf "%-22s %-5s %-9s %-12s %s%s\n" "$node" "$gpu" "$temp" "$clock_val" "$status" "$cordoned"
    done <<< "$output"
  done
