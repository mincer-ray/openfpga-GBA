#!/usr/bin/env bash
set -euo pipefail

BRANCH=$(git rev-parse --abbrev-ref HEAD)

echo "Finding latest build run on branch '$BRANCH'..."
RUN_ID=$(gh run list --workflow=build.yml --branch="$BRANCH" --limit=1 --json databaseId --jq '.[0].databaseId')

if [ -z "$RUN_ID" ]; then
  echo "No workflow runs found for branch '$BRANCH'."
  exit 1
fi

echo "Watching run $RUN_ID..."
gh run watch "$RUN_ID"

STATUS=$(gh run view "$RUN_ID" --json conclusion --jq '.conclusion')
if [ "$STATUS" != "success" ]; then
  echo "Build failed (status: $STATUS)."
  echo "Download debug artifacts with: gh run download $RUN_ID -n debug-output"
  exit 1
fi

echo "Downloading bitstream and reports..."
mkdir -p build_output
gh run download "$RUN_ID" -n bitstream -D build_output
gh run download "$RUN_ID" -n reports -D build_output 2>/dev/null || true

echo "Done! Bitstream at build_output/bitstream.rbf_r"
