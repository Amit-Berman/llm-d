# Build and deploy a local EPP image

Use this guide after changing EPP Go code. The source repository on this Mac
is `/Users/amitberman/llm-d-inference-scheduler`. The container configuration
is in `/Users/amitberman/llm-d/local-epp`.

## 1. Check Podman

```bash
podman machine list
podman images
```

If the machine is stopped, run `podman machine start`.

## 2. Build a new image

Choose a unique tag for each build. Run these commands in the same terminal:

```bash
cd /Users/amitberman/llm-d-inference-scheduler
git status --short
export EPP_IMAGE="localhost/llm-d-epp:local-$(date +%Y%m%d-%H%M%S)"

make image-build-epp \
  CONTAINER_RUNTIME=podman \
  EPP_IMAGE="$EPP_IMAGE" \
  TARGETARCH=arm64
```

`arm64` targets the Apple Silicon Podman VM. Use `TARGETARCH=amd64` for an
Intel Linux destination. The Make target uses `Dockerfile.epp`, downloads Go
dependencies, compiles EPP for Linux, and packages `/app/epp` in a minimal
runtime image. Host Go is not required. The build includes local source edits;
the embedded commit SHA identifies HEAD and does not describe uncommitted edits.

Verify the image before replacing the running container:

```bash
podman image inspect "$EPP_IMAGE" --format '{{.Id}} {{.Os}}/{{.Architecture}}'
podman run --rm "$EPP_IMAGE" --help
```

Run the source repository's appropriate tests for your code change. For the
full pre-merge checks, use `make presubmit CONTAINER_RUNTIME=podman`.

## 3. Replace the EPP container

A container keeps using its original image after a rebuild or retag.
`podman restart` reloads configuration but does not switch images.

Save the existing container for rollback, then start the new one:

```bash
cd /Users/amitberman/llm-d
export EPP_BACKUP="epp-backup-$(date +%Y%m%d-%H%M%S)"
podman stop epp-kv-event-log
podman rename epp-kv-event-log "$EPP_BACKUP"
EPP_IMAGE="$EPP_IMAGE" bash local-epp/start.sh
```

For a first deployment with no existing container, run only the last command.
If you opened a new terminal, set EPP_IMAGE to the tag you built first.

The script mounts this directory read-only and exposes localhost ports 9002
(ext_proc gRPC), 9003 (gRPC health), and 9090 (HTTP metrics). Its default image,
when EPP_IMAGE is unset, is `localhost/llm-d-epp:kv-event-log`.

## 4. Verify and view logs

```bash
podman ps -a --filter name=epp-kv-event-log
podman inspect epp-kv-event-log --format '{{.ImageName}} {{.Image}}'
curl --fail http://127.0.0.1:9090/metrics
podman logs --tail 100 -f epp-kv-event-log
```

Press Ctrl+C to stop following logs; EPP keeps running. To filter KV messages:

```bash
podman logs --tail 100 -f epp-kv-event-log 2>&1 | grep -Ei 'kv|subscriber|events|decode'
```

The launch script sets `--v=4` for debug logs. Subscriber startup confirms the
local subscriber was created. To verify ingestion, start the simulator, send
inference traffic that creates cache blocks, and check for event processing
and successful decoding. ZeroMQ can create a subscriber with no publisher
available. A successful metrics response also does not prove ingestion.

## 5. Simulator and tokenizer settings

The current configuration uses:

| Component | Address or setting |
| --- | --- |
| Model | `openai/gpt-oss-120b` |
| Simulator HTTP | Mac host `192.168.127.254:8000` |
| Simulator KV publisher | `tcp://*:5556` |
| KV replay | Mac host port `5559`, if supported by the publisher |
| KV topic | `kv@192.168.127.254:8000@openai/gpt-oss-120b` |
| KV event decoder | `engineType: sglang` |
| Tokenizer renderer | `http://host.containers.internal:8001` |
| EPP block size | 64 tokens |

Check the Mac host address with:

```bash
podman machine ssh getent hosts host.containers.internal
```

If it changes, update endpoints.yaml and the simulator's KV topic together.
The renderer must support vLLM-compatible `/v1/*/render` APIs with the same
model tokenizer. EPP selects the simulator endpoint; an Envoy gateway forwards
the inference request. Building the EPP image does not start those services.
See [README.md](README.md) for simulator arguments and setup limitations.

## 6. Roll back if needed

In the same terminal where EPP_BACKUP was set:

```bash
podman stop epp-kv-event-log
podman rm epp-kv-event-log
podman rename "$EPP_BACKUP" epp-kv-event-log
podman start epp-kv-event-log
```

If the new container failed to be created, skip stopping and removing it.
Rollback restores the previous image; the mounted configuration files remain
the same, so restore those separately if you changed them.

## Configuration-only changes

For plugin settings or the tokenizer URL, edit config.yaml and run:

```bash
podman restart epp-kv-event-log
```

Changes to endpoints.yaml are watched automatically. A rebuild is needed for
Go source or Dockerfile changes.
