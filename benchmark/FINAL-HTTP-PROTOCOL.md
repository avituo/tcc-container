# Definitive HTTP benchmark protocol

## Image set

Build time is measured only by `benchmark/scripts/run-build-condition.sh`. It performs the no-cache builds and must be completed before the definitive HTTP benchmark conditions.

After those builds, freeze the one image set used by the whole definitive run set:

```sh
benchmark/scripts/freeze-final-images.sh
```

This writes `benchmark/final-image-manifest.properties`, which is intentionally local and is not overwritten. It contains the Docker image IDs for the monolith, the microservice gateway and services, and MySQL.

Every non-pilot `run-condition.sh` invocation verifies that the locally tagged images match this manifest before it starts containers. It then records the image ID actually used by each request-serving component and database in that condition's `condition.properties`. A mismatch or a missing manifest aborts the condition before database reset, authentication, or HTTP load.

Consequently, all definitive HTTP conditions are executed against the same prebuilt image set. `run-condition.sh` starts the stack with `docker compose up --no-build` and does not build images.

## Condition sequence

For each condition, the runner starts the already-built images, resets and validates the deterministic dataset, authenticates outside the measured workload, stabilizes, runs the excluded warm-up, and then performs the timed HTTP workload with one-second Docker resource sampling. It stops the stack after the cooldown.

Pilot conditions are excluded from the frozen-manifest requirement, but still record the image IDs used in their metadata.
