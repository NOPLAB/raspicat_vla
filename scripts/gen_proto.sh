#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${REPO_ROOT}/src/raspicat_vla_proto/raspicat_vla_proto"
PROTO_DIR="${REPO_ROOT}/proto"

mkdir -p "${OUT_DIR}"

python3 -m grpc_tools.protoc \
    -I "${PROTO_DIR}" \
    --python_out="${OUT_DIR}" \
    --grpc_python_out="${OUT_DIR}" \
    "${PROTO_DIR}/raspicat_vla.proto"

# grpc_tools generates `import raspicat_vla_pb2` -- rewrite to relative.
sed -i 's/^import raspicat_vla_pb2/from . import raspicat_vla_pb2/' "${OUT_DIR}/raspicat_vla_pb2_grpc.py"

echo "Generated:"
ls -1 "${OUT_DIR}"/raspicat_vla_pb2*.py
