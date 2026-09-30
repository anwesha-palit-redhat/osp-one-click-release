#!/bin/bash
# Copy 1.23.3 stage index images to quay.io/openshift-pipeline
# Source: IIB images from index stage releases
#
# Generated: 2026-10-07_02-10-38_IST
# Prerequisites: VPN connected, quay.io login active
#
# Stage releases used:
#   openshift-pipelines-index-4-14-1-23-stage-rp-9ktjs (openshift-pipelines-index-4-14-1-23-stage-rp)
#   openshift-pipelines-index-4-16-1-23-stage-rp-gzms6 (openshift-pipelines-index-4-16-1-23-stage-rp)
#   openshift-pipelines-index-4-18-1-23-stage-rp-jrkhf (openshift-pipelines-index-4-18-1-23-stage-rp)
#   openshift-pipelines-index-4-19-1-23-stage-rp-7484b (openshift-pipelines-index-4-19-1-23-stage-rp)
#   openshift-pipelines-index-4-20-1-23-stage-rp-rwlnz (openshift-pipelines-index-4-20-1-23-stage-rp)
#   openshift-pipelines-index-4-21-1-23-stage-rp-rsxf6 (openshift-pipelines-index-4-21-1-23-stage-rp)
#   openshift-pipelines-index-4-22-1-23-stage-rp-lz7zz (openshift-pipelines-index-4-22-1-23-stage-rp)
#   openshift-pipelines-index-4-23-1-23-stage-rp-tcwvp (openshift-pipelines-index-4-23-1-23-stage-rp)
#   openshift-pipelines-1-23-fbc-stage-rp-rvh4b (openshift-pipelines-1-23-fbc-stage-rp)

set -euo pipefail

echo "=== Logging into quay.io ==="
source "$(dirname "$0")/../.env"
echo "${QUAY_PASSWORD}" | skopeo login quay.io -u "${QUAY_USER}" --password-stdin

echo "=== Running image copy script ==="
echo "Copying 1.23.3 stage index images to quay.io..."

# OCP 4.14
skopeo copy --all \
  docker://registry-proxy.engineering.redhat.com/rh-osbs/iib@sha256:7715aa65b5a17c8ac4060820d9528e29598d90b7ef36a741738a8e09aa600b9c \
  docker://quay.io/openshift-pipeline/pipelines-index-4.14:v1.23.3-stage \
  --preserve-digests
# OCP 4.16
skopeo copy --all \
  docker://registry-proxy.engineering.redhat.com/rh-osbs/iib@sha256:a05ab3c42e5e8cc7b80e8d1365b423b558a94b3898363c3fbdab7dea650f5fb8 \
  docker://quay.io/openshift-pipeline/pipelines-index-4.16:v1.23.3-stage \
  --preserve-digests
# OCP 4.18
skopeo copy --all \
  docker://registry-proxy.engineering.redhat.com/rh-osbs/iib@sha256:019744b5a53c7d702c7566a2c48481751e35f2b6647084cdb53b3fe00ef3b7dc \
  docker://quay.io/openshift-pipeline/pipelines-index-4.18:v1.23.3-stage \
  --preserve-digests
# OCP 4.19
skopeo copy --all \
  docker://registry-proxy.engineering.redhat.com/rh-osbs/iib@sha256:27ff4a3853800f5ad64b5ea687449593d44f3bb5601a82a785edfdd58d0a6c18 \
  docker://quay.io/openshift-pipeline/pipelines-index-4.19:v1.23.3-stage \
  --preserve-digests
# OCP 4.20
skopeo copy --all \
  docker://registry-proxy.engineering.redhat.com/rh-osbs/iib@sha256:6f397bb93a25560deac1117ee79e709c0ddbf4a00eebc77d708e4186c575e2f4 \
  docker://quay.io/openshift-pipeline/pipelines-index-4.20:v1.23.3-stage \
  --preserve-digests
# OCP 4.21
skopeo copy --all \
  docker://registry-proxy.engineering.redhat.com/rh-osbs/iib@sha256:6d01d7ea97163cf05b26bfe3105ee8e6ad3a5aafa6aceaf25af68dad65a1f825 \
  docker://quay.io/openshift-pipeline/pipelines-index-4.21:v1.23.3-stage \
  --preserve-digests
# OCP 4.22
skopeo copy --all \
  docker://registry-proxy.engineering.redhat.com/rh-osbs/iib@sha256:81d435225ea28260486f1d7e51bc70c36752a255b5e96df442bb044a77d96e89 \
  docker://quay.io/openshift-pipeline/pipelines-index-4.22:v1.23.3-stage \
  --preserve-digests
# OCP 4.23
skopeo copy --all \
  docker://registry-proxy.engineering.redhat.com/rh-osbs/iib@sha256:194655e59cdb51558d6207f508cc3f285f932fc64af990d36a2d284ea8490fdf \
  docker://quay.io/openshift-pipeline/pipelines-index-4.23:v1.23.3-stage \
  --preserve-digests
# OCP 5.0
skopeo copy --all \
  docker://registry-proxy.engineering.redhat.com/rh-osbs/iib@sha256:f66827b47b863599b9b6ec95e79b2b27197b3b48105cc2fedb4e2beec509cb35 \
  docker://quay.io/openshift-pipeline/pipelines-index-5.0:v1.23.3-stage \
  --preserve-digests

echo "Done — all index images copied."
