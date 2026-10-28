# 5. One remote BuildKit builder per machine, with mTLS

Status: accepted

## Context

buildx picks a node of a multi-node builder by platform only, so several amd64
nodes in one builder all receive work on the first node.

## Decision

One `buildkitd` per machine, one buildx builder per daemon, mTLS required, and a
wrapper that routes each target to a builder.
