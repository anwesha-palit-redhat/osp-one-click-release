#!/usr/bin/env bash

#Create Task
oc apply -f tasks -f pipelines

tkn pipeline start konflux-release-pipeline \
  --serviceaccount=gh-action \
  --param RELEASE=1.21 \
  --param ENVIRONMENT=stage \
  --param TAG=v1.21.2-test \
  --use-param-defaults \
  --showlog

#tkn task start konflux-release-task \
#  --serviceaccount=gh-action \
#  --param APPLICATION=openshift-pipelines-core-1-22 \
#  --param ENVIRONMENT=stage \
#  --showlog
#
#tkn task start konflux-release-task \
#  --serviceaccount=gh-action \
#  --param APPLICATION=openshift-pipelines-bundle-1-22 \
#  --param ENVIRONMENT=stage \
#  --showlog
