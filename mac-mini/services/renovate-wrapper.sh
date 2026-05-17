#!/bin/sh
export RENOVATE_TOKEN=$(cat $RENOVATE_TOKEN_FILE)
export RENOVATE_GITHUB_COM_TOKEN=$(cat $GITHUB_COM_TOKEN_FILE)
exec renovate "$@"
