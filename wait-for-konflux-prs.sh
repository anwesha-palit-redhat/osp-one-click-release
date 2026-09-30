#!/usr/bin/env bash
set -e

#tkn pr ls

#?(@.type=='Succeeded')
oc get pr -o json | jq '.items[] | select( .status.conditions[].type == "Succeeded") | "\(.metadata.name) ==== \(.status.conditions[].message)"  '
