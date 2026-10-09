# Local EPP with the SGLang simulator

For rebuilding EPP and replacing the container, see [BUILD-IMAGE.md](BUILD-IMAGE.md).

Container: `epp-kv-event-log`, image: `localhost/llm-d-epp:kv-event-log`.
Start a new container with `bash local-epp/start.sh` from the repository root.
After editing config.yaml, run `podman restart epp-kv-event-log`.

EPP exposes ext_proc gRPC on localhost:9002, gRPC health on localhost:9003,
and HTTP metrics at http://localhost:9090/metrics. The gRPC serving listener
uses plaintext for local development.

The simulator is a separate process on the Mac. Add these arguments to its
normal launch command (including its required --sim-config-path):

```bash
--model-path=openai/gpt-oss-120b \
--host=0.0.0.0 --port=8000 --page-size=64 --enable-metrics \
--kv-events-config='{"publisher":"zmq","endpoint":"tcp://*:5556","topic":"kv@192.168.127.254:8000@openai/gpt-oss-120b"}'
```

The topic address must match endpoints.yaml, so EPP can associate events with
the registered inference endpoint. 192.168.127.254 is the Mac host address
resolved from this Podman VM. Recheck it with
`podman machine ssh getent hosts host.containers.internal` if the VM changes.
Replay is configured on port 5559 as in the guide; actual replay support
depends on the simulator publisher.

For text prompts, config.yaml expects a separate vLLM-compatible render
service on the Mac's port 8001 serving the GPT-OSS-120B tokenizer. This service
has not been started. SGLang's inference HTTP endpoint is not a replacement
for vLLM's /v1/*/render endpoints. An Envoy gateway is also needed to route
HTTP inference requests through EPP; EPP itself serves ext_proc gRPC.

The prefix affinity throughput value 15926 comes from the guide's Qwen
calibration. Recalibrate it for the simulator's GPT-OSS timing model.

At setup time, the simulator was not running. Its .venv-llmd environment in
/Users/amitberman/sglang/tools/sglang-simulator failed to launch: without
PYTHONPATH it could not import sglang; with PYTHONPATH pointing to the checkout's
python directory, it could not import triton. Simulator startup and end-to-end
KV-event ingestion remain unverified.

```bash
podman logs --tail 50 epp-kv-event-log
curl http://localhost:9090/metrics
podman stop epp-kv-event-log
```
