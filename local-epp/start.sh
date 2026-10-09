#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
EPP_IMAGE="${EPP_IMAGE:-localhost/llm-d-epp:kv-event-log}"
exec podman run -d --name epp-kv-event-log \
  -p 127.0.0.1:9002:9002 \
  -p 127.0.0.1:9003:9003 \
  -p 127.0.0.1:9090:9090 \
  -v "$PWD:/etc/epp:ro" \
  "$EPP_IMAGE" \
  --config-file=/etc/epp/config.yaml \
  --pool-name=sglang-simulator --pool-namespace=local \
  --grpc-port=9002 --grpc-health-port=9003 --metrics-port=9090 \
  --secure-serving=false --metrics-endpoint-auth=false --tracing=false --v=4
