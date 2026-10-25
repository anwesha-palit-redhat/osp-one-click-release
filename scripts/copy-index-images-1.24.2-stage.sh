#!/bin/bash
# Copy 1.24.2 stage index images to quay.io/openshift-pipeline
# Source: IIB images from index stage releases
#
# Generated: 2026-10-25_16-47-47_IST
# Prerequisites: VPN connected, quay.io login active
#
# Stage releases used:
#   openshift-pipelines-index-4-14-1-24-stage-rp-hsv7r (openshift-pipelines-index-4-14-1-24-stage-rp)
#   openshift-pipelines-index-4-16-1-24-stage-rp-s7hmv (openshift-pipelines-index-4-16-1-24-stage-rp)
#   openshift-pipelines-index-4-18-1-24-stage-rp-2c9sg (openshift-pipelines-index-4-18-1-24-stage-rp)
#   openshift-pipelines-index-4-19-1-24-stage-rp-48d5q (openshift-pipelines-index-4-19-1-24-stage-rp)
#   openshift-pipelines-index-4-20-1-24-stage-rp-bqh8r (openshift-pipelines-index-4-20-1-24-stage-rp)
#   openshift-pipelines-index-4-21-1-24-stage-rp-8fdxb (openshift-pipelines-index-4-21-1-24-stage-rp)
#   openshift-pipelines-index-4-22-1-24-stage-rp-ssz86 (openshift-pipelines-index-4-22-1-24-stage-rp)
#   openshift-pipelines-index-4-23-1-24-stage-rp-lchzb (openshift-pipelines-index-4-23-1-24-stage-rp)
#   openshift-pipelines-index-5-0-1-24-stage-rp-f8g2g (openshift-pipelines-index-5-0-1-24-stage-rp)

set -euo pipefail

echo "=== Logging into quay.io ==="
source "$(dirname "$0")/../.env"
echo "${QUAY_PASSWORD}" | skopeo login quay.io -u "${QUAY_USER}" --password-stdin

echo "=== Running image copy script ==="
echo "Copying 1.24.2 stage index images to quay.io..."

# OCP 4.14
skopeo copy --all \
  docker://registry-proxy.engineering.redhat.com/rh-osbs/iib@sha256:980ee8b0eced44169540c7d335f4f253e50eaba94dea7a735ced6b30bc318b3a \
  docker://quay.io/openshift-pipeline/pipelines-index-4.14:v1.24.2-stage \
  --preserve-digests
# OCP 4.16
skopeo copy --all \
  docker://registry-proxy.engineering.redhat.com/rh-osbs/iib@sha256:e5aa2218bb517d5b6523ae8d48bb4aee4886cb8306b05fe54f6c77208e567e77 \
  docker://quay.io/openshift-pipeline/pipelines-index-4.16:v1.24.2-stage \
  --preserve-digests
# OCP 4.18
skopeo copy --all \
  docker://registry-proxy.engineering.redhat.com/rh-osbs/iib@sha256:08ee4bb003525b778c1ad95319cdd739c369bdc562eec9e38ff34db64d310db3 \
  docker://quay.io/openshift-pipeline/pipelines-index-4.18:v1.24.2-stage \
  --preserve-digests
# OCP 4.19
skopeo copy --all \
  docker://registry-proxy.engineering.redhat.com/rh-osbs/iib@sha256:4a633704f882ab9aa75187496de0fb2b0f0e65c67881fb537a0303d94f5b2931 \
  docker://quay.io/openshift-pipeline/pipelines-index-4.19:v1.24.2-stage \
  --preserve-digests
# OCP 4.20
skopeo copy --all \
  docker://registry-proxy.engineering.redhat.com/rh-osbs/iib@sha256:2f756658064acfacb8a6862ea14398c54491b6ecf4dc4c9c57fc8e8e75e5e5b9 \
  docker://quay.io/openshift-pipeline/pipelines-index-4.20:v1.24.2-stage \
  --preserve-digests
# OCP 4.21
skopeo copy --all \
  docker://registry-proxy.engineering.redhat.com/rh-osbs/iib@sha256:bd690ff85df316e3d86f2bf1b682051a9d057a9d7ddfb7f80f34687d59a590d6 \
  docker://quay.io/openshift-pipeline/pipelines-index-4.21:v1.24.2-stage \
  --preserve-digests
# OCP 4.22
skopeo copy --all \
  docker://registry-proxy.engineering.redhat.com/rh-osbs/iib@sha256:9d442dff8eb321e87d7c7cadb2abb22d735176b874e587b861b080d5ad3191c3 \
  docker://quay.io/openshift-pipeline/pipelines-index-4.22:v1.24.2-stage \
  --preserve-digests
# OCP 4.23
skopeo copy --all \
  docker://registry-proxy.engineering.redhat.com/rh-osbs/iib@sha256:47aabe2ae09ed228473a278df98a84189af01bbd188aabd60010fea9b2275acc \
  docker://quay.io/openshift-pipeline/pipelines-index-4.23:v1.24.2-stage \
  --preserve-digests
# OCP 5.0
skopeo copy --all \
  docker://registry-proxy.engineering.redhat.com/rh-osbs/iib@sha256:43ad080db802f6a1c2a624fadf5f42993fbbbcf47adcdbf79bbb2bfecd8db1b9 \
  docker://quay.io/openshift-pipeline/pipelines-index-5.0:v1.24.2-stage \
  --preserve-digests

echo "Done — all index images copied."