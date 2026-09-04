#!/usr/bin/env bash

# Backwards-compatible entry point for existing student instructions.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/lab.sh" "$@"
