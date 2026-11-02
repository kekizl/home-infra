#!/usr/bin/env bash
# Single source of truth for commit message validation.
# Usage: validate-commit-msg.sh "<first line of commit message>"
set -euo pipefail

header="${1-}"

regex='^(feat|fix|perf|revert|docs|style|chore|refactor|test|build|ci)(\([a-zA-Z0-9_-]+\))?!?: .+'

# Skip merges, git-generated reverts, and autosquash commits
if [[ "$header" =~ ^Merge[[:space:]] || "$header" =~ ^Revert[[:space:]]\" || "$header" =~ ^(fixup|squash)!  ]]; then
  exit 0
fi

if [[ ! "$header" =~ $regex ]]; then
  echo -e "\n\033[1;31m❌ Invalid commit message format\033[0m"
  echo -e "Got: \"\033[1;33m${header}\033[0m\"\n"
  echo "Must follow Conventional Commits: type(optional-scope)!: description"
  echo -e "  Example: \033[1;32mfeat: add automated backup script\033[0m"
  echo -e "  Example: \033[1;32mchore(docker): update container port bindings\033[0m"
  echo -e "\nAllowed types:"
  echo -e "  feat, fix, perf, revert, docs, style, chore, refactor, test, build, ci\n"
  exit 1
fi

