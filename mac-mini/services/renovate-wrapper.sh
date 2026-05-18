#!/bin/sh
export RENOVATE_TOKEN=$(cat $RENOVATE_TOKEN_FILE)
exec renovate "$@"
