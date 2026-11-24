#!/bin/bash
# Copy 1.24.4 stage index images to quay.io/openshift-pipeline
# Source: IIB images from index stage releases
#
# Generated: 2026-11-24_17-42-13_IST
# Prerequisites: VPN connected, quay.io login active
#
# Stage releases used:
#   openshift-pipelines-index-4-14-1-24-stage-rp-kjs8n (openshift-pipelines-index-4-14-1-24-stage-rp)
#   openshift-pipelines-index-4-16-1-24-stage-rp-2llm5 (openshift-pipelines-index-4-16-1-24-stage-rp)
#   openshift-pipelines-index-4-18-1-24-stage-rp-lvgf8 (openshift-pipelines-index-4-18-1-24-stage-rp)
#   openshift-pipelines-index-4-19-1-24-stage-rp-ldz5s (openshift-pipelines-index-4-19-1-24-stage-rp)
#   openshift-pipelines-index-4-20-1-24-stage-rp-xqzgm (openshift-pipelines-index-4-20-1-24-stage-rp)
#   openshift-pipelines-index-4-21-1-24-stage-rp-tqzkg (openshift-pipelines-index-4-21-1-24-stage-rp)
#   openshift-pipelines-index-4-22-1-24-stage-rp-n29bt (openshift-pipelines-index-4-22-1-24-stage-rp)
#   openshift-pipelines-index-5-0-1-24-stage-rp-6qtr6 (openshift-pipelines-index-5-0-1-24-stage-rp)

set -euo pipefail

echo "=== Logging into quay.io ==="
source "$(dirname "$0")/../.env"
echo "${QUAY_PASSWORD}" | skopeo login quay.io -u "${QUAY_USER}" --password-stdin

echo "=== Running image copy script ==="
echo "Copying 1.24.4 stage index images to quay.io..."

# OCP 4.14
skopeo copy --all \
  docker://registry-proxy.engineering.redhat.com/rh-osbs/iib@sha256:845681d1be0d6aedda5f52bef825b5680993d70581d5323fb0f3fa8f7fb23e25 \
  docker://quay.io/openshift-pipeline/pipelines-index-4.14:v1.24.4-stage \
  --preserve-digests
# OCP 4.16
skopeo copy --all \
  docker://registry-proxy.engineering.redhat.com/rh-osbs/iib@sha256:062d5512a6a9ddbb1f8629cea3debadfc0e2eac1fb032830dc104c5985d9da0f \
  docker://quay.io/openshift-pipeline/pipelines-index-4.16:v1.24.4-stage \
  --preserve-digests
# OCP 4.18
skopeo copy --all \
  docker://registry-proxy.engineering.redhat.com/rh-osbs/iib@sha256:c0ad86cb17f27925d4fa59d90d598810ddba09f2018a0f1be04cac1b9560fd85 \
  docker://quay.io/openshift-pipeline/pipelines-index-4.18:v1.24.4-stage \
  --preserve-digests
# OCP 4.19
skopeo copy --all \
  docker://registry-proxy.engineering.redhat.com/rh-osbs/iib@sha256:dc8ebbc200add18be0d6cbe9f5f19efa343b8f20e2142f8781c3d70079606eb7 \
  docker://quay.io/openshift-pipeline/pipelines-index-4.19:v1.24.4-stage \
  --preserve-digests
# OCP 4.20
skopeo copy --all \
  docker://registry-proxy.engineering.redhat.com/rh-osbs/iib@sha256:8d16b14b81dec75d1ee2c815f0f96f3c1ff6f263fd80ffd57e21e139ce823f6d \
  docker://quay.io/openshift-pipeline/pipelines-index-4.20:v1.24.4-stage \
  --preserve-digests
# OCP 4.21
skopeo copy --all \
  docker://registry-proxy.engineering.redhat.com/rh-osbs/iib@sha256:3a586d0fe54cbc98d7ef597ff3b1ce731b89ed844c31e19e5ca02941c4061308 \
  docker://quay.io/openshift-pipeline/pipelines-index-4.21:v1.24.4-stage \
  --preserve-digests
# OCP 4.22
skopeo copy --all \
  docker://registry-proxy.engineering.redhat.com/rh-osbs/iib@sha256:2e21058a9c48d9329ce029a0b33a59f10386b595332b9a9838bfdbd6b4fcad98 \
  docker://quay.io/openshift-pipeline/pipelines-index-4.22:v1.24.4-stage \
  --preserve-digests
# OCP 5.0
skopeo copy --all \
  docker://registry-proxy.engineering.redhat.com/rh-osbs/iib@sha256:fe8e5b6ce91dc56304fdc97afedec43465a380748e8dc2ea4e2713bfffec2a9a \
  docker://quay.io/openshift-pipeline/pipelines-index-5.0:v1.24.4-stage \
  --preserve-digests

echo "Done — all index images copied."
