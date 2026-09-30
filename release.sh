#!/usr/bin/env bash

oc apply -f tasks/ -f pipelines/

#echo "Generating Release Config"
#oc apply -f tasks/release-config-task.yaml
#tkn task start release-config-task \
#  --serviceaccount=gh-action \
#  --param RELEASE=1.15 \
#  --use-param-defaults \
#  -w name=source,emptyDir="" \
#  --showlog

#echo "Processing PRs"
#oc apply -f tasks/osp-github-pr-processor.yaml
#tkn task start osp-github-pr-processor \
#  --serviceaccount=gh-action \
#  --param RELEASE=1.21 \
#  --use-param-defaults \
#  --showlog

echo "Running Release "
#oc apply -f tasks/osp-github-pr-processor.yaml
tkn pipeline start openshift-pipelines-release \
  --serviceaccount=gh-action \
  --param RELEASE=1.22 \
  --use-param-defaults \
  -w name=source,emptyDir="" \
  --showlog
