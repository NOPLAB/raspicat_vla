#!/usr/bin/env bash
# docker/run.sh — wrapper for building and running raspicat-vla Docker images.
#
# Subcommands:
#   build TARGET            asyncvla | omnivla | test | real | sim | --all
#   run MODEL MODE [OPTS]   MODEL = asyncvla | omnivla
#                           MODE  = --remote {--cpu|--gpu}
#                                   --real --host HOST
#                                   --sim --host HOST
#
# Run `run.sh --help` for the full reference.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRPC_PORT="${GRPC_PORT:-50051}"
HF_CACHE_DIR="${HF_CACHE_DIR:-${HOME}/.cache/huggingface}"

# Image / Dockerfile / model knob registries. Bash 4 associative arrays.
declare -A IMAGES=(
    [asyncvla]="raspicat-vla-asyncvla"
    [omnivla]="raspicat-vla-omnivla"
    [test]="raspicat-vla-test"
    [real]="raspicat-vla-real"
    [sim]="raspicat-vla-sim"
)
declare -A DOCKERFILES=(
    [asyncvla]="docker/Dockerfile.asyncvla"
    [omnivla]="docker/Dockerfile.omnivla"
    [test]="docker/Dockerfile.test"
    [real]="docker/Dockerfile.real"
    [sim]="docker/Dockerfile.sim"
)
declare -A RESUME_STEP=(
    [asyncvla]=750000
    [omnivla]=120000
)
declare -A WEIGHTS_DIR=(
    [asyncvla]="/workspace/AsyncVLA_release"
    [omnivla]="/workspace/omnivla-original"
)

usage() {
    cat <<'EOF'
Usage: run.sh COMMAND [ARGS]

Commands:
  build TARGET            Build a Docker image
    TARGET = asyncvla | omnivla | test | real | sim | --all
  run MODEL MODE [OPTS]   Run a configuration
    MODEL = asyncvla | omnivla
    MODE:
      --remote {--cpu|--gpu} [--host BIND[:PORT]]
                                    Host the cloud-side gRPC server here.
                                    Uses Dockerfile.<MODEL>. BIND defaults to
                                    0.0.0.0 (all interfaces). Optional :PORT
                                    overrides $GRPC_PORT.
      --real --host HOST[:PORT]     Edge stack here, talking to a cloud server
                                    at HOST:PORT (PORT defaults to $GRPC_PORT).
                                    Uses Dockerfile.real.
      --sim  --host HOST[:PORT]     Edge + Gazebo simulation, cloud at
                                    HOST:PORT. Uses Dockerfile.sim. Plan 3 wip.
  help, -h, --help        Show this help

Examples:
  run.sh build asyncvla
  run.sh build --all
  run.sh run asyncvla --remote --gpu                       # bind 0.0.0.0:50051
  run.sh run asyncvla --remote --gpu --host :8080          # bind 0.0.0.0:8080
  run.sh run asyncvla --remote --cpu --host 127.0.0.1      # localhost only
  run.sh run omnivla  --remote --gpu --host 10.0.0.5:9000  # specific NIC + port
  run.sh run asyncvla --real --host 192.168.1.2            # default port
  run.sh run asyncvla --real --host 192.168.1.2:8080
  run.sh run omnivla  --sim  --host 192.168.1.2:9000

Environment overrides:
  GRPC_PORT     gRPC port (default 50051)
  HF_CACHE_DIR  HuggingFace cache mount (default $HOME/.cache/huggingface)
EOF
}

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
err()  { printf '\033[1;31m!!\033[0m  %s\n' "$*" >&2; }

# split_hostport HOST[:PORT] DEFAULT_HOST DEFAULT_PORT -> "HOST PORT" on stdout.
# Empty HOST (e.g. ":8080") falls back to DEFAULT_HOST. Missing :PORT -> DEFAULT_PORT.
split_hostport() {
    local raw=$1 default_host=$2 default_port=$3
    local host port
    if [[ $raw == *:* ]]; then
        host=${raw%:*}
        port=${raw##*:}
    else
        host=$raw
        port=$default_port
    fi
    [[ -z $host ]] && host=$default_host
    if ! [[ $port =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        err "invalid port in '$raw'"
        return 1
    fi
    printf '%s %s\n' "$host" "$port"
}

build_one() {
    local target=$1
    local dfile_rel="${DOCKERFILES[$target]:-}"
    local image="${IMAGES[$target]:-}"
    [[ -n $dfile_rel && -n $image ]] || { err "unknown build target: $target"; return 1; }
    local dfile="${REPO_ROOT}/${dfile_rel}"
    [[ -f $dfile ]] || { err "Dockerfile not found: $dfile"; return 1; }
    log "building ${image} from ${dfile_rel}"
    docker build -f "$dfile" -t "$image" "$REPO_ROOT"
}

cmd_build() {
    local target=${1:-}
    case $target in
        --all)
            local rc=0
            for t in asyncvla omnivla test real sim; do
                build_one "$t" || rc=1
            done
            return $rc
            ;;
        asyncvla|omnivla|test|real|sim)
            build_one "$target"
            ;;
        '')
            err "build: missing target"
            usage
            return 1
            ;;
        *)
            err "build: unknown target '$target'"
            usage
            return 1
            ;;
    esac
}

run_remote() {
    local model=$1 device=$2 bind_host=$3 bind_port=$4
    local image="${IMAGES[$model]}"
    local resume_step="${RESUME_STEP[$model]}"
    local weights="${WEIGHTS_DIR[$model]}"
    local gpu_flag="" device_arg="cpu"
    if [[ $device == gpu ]]; then
        gpu_flag="--gpus all"
        device_arg="cuda:0"
    fi

    log "${model} remote backend on ${device_arg}, bind ${bind_host}:${bind_port}"
    # shellcheck disable=SC2086
    docker run --rm $gpu_flag --network host \
        -v "$REPO_ROOT:/workspace" \
        -v "$HF_CACHE_DIR:/root/.cache/huggingface" \
        "$image" bash -lc "
            cd /workspace
            pip install -e src/raspicat_vla_proto src/raspicat_vla_remote >/dev/null 2>&1 || true
            exec python3 -m raspicat_vla_remote.server_main \
                --backend ${model} \
                --host ${bind_host} \
                --port ${bind_port} \
                --vla-path ${weights} \
                --resume-step ${resume_step} \
                --device ${device_arg}
        "
}

# --real and --sim share the edge launch; only the image differs.
run_edge() {
    local model=$1 host=$2 port=$3 image=$4 mode=$5
    log "${model} edge (${mode}, image=${image}); cloud=${host}:${port}"
    docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
        --network host \
        -v "$REPO_ROOT:/workspace" \
        -v "$HF_CACHE_DIR:/tmp/.cache/huggingface" \
        "$image" bash -lc "
            source /opt/ros/humble/setup.bash
            cd /workspace
            [[ -f install/setup.bash ]] && source install/setup.bash
            exec ros2 launch raspicat_vla_bringup edge_only.launch.py \
                remote_address:=${host}:${port} \
                adapter_kind:=${model} \
                with_follower:=true
        "
}

run_real() {
    local model=$1 host=$2 port=$3
    local image="${IMAGES[real]}"
    if ! docker image inspect "$image" >/dev/null 2>&1; then
        warn "image ${image} not found; falling back to ${IMAGES[test]}. Run \`run.sh build real\` for the dedicated image."
        image="${IMAGES[test]}"
    fi
    if [[ $model == asyncvla ]]; then
        warn "AsyncVLA edge needs torch + MBRA on PYTHONPATH. The base test image"
        warn "doesn't ship those by default; build a Dockerfile.real that includes them"
        warn "(or extend Dockerfile.test) before running on a real raspicat."
    fi
    run_edge "$model" "$host" "$port" "$image" real
}

run_sim() {
    local model=$1 host=$2 port=$3
    local image="${IMAGES[sim]}"
    if ! docker image inspect "$image" >/dev/null 2>&1; then
        warn "image ${image} not found; falling back to ${IMAGES[test]}. Plan 3 will"
        warn "ship a Dockerfile.sim with Gazebo + adapter deps; this fallback runs the"
        warn "edge node only (no Gazebo)."
        image="${IMAGES[test]}"
    fi
    run_edge "$model" "$host" "$port" "$image" sim
}

cmd_run() {
    local model=${1:-}
    case $model in
        asyncvla|omnivla) ;;
        '')
            err "run: missing model (asyncvla|omnivla)"; usage; return 1 ;;
        *)
            err "run: unknown model '$model'"; usage; return 1 ;;
    esac
    shift

    local mode='' host='' device=''
    while [[ $# -gt 0 ]]; do
        case $1 in
            --remote) mode=remote; shift ;;
            --real)   mode=real; shift ;;
            --sim)    mode=sim; shift ;;
            --host)
                [[ $# -ge 2 ]] || { err "--host requires an argument"; return 1; }
                host=$2; shift 2 ;;
            --cpu)    device=cpu; shift ;;
            --gpu)    device=gpu; shift ;;
            -h|--help) usage; return 0 ;;
            *) err "run: unknown option '$1'"; usage; return 1 ;;
        esac
    done

    case $mode in
        remote)
            if [[ -z $device ]]; then
                err "--remote requires --cpu or --gpu"; return 1
            fi
            local pair bind_host bind_port
            pair=$(split_hostport "${host:-0.0.0.0}" "0.0.0.0" "$GRPC_PORT") || return 1
            read -r bind_host bind_port <<<"$pair"
            run_remote "$model" "$device" "$bind_host" "$bind_port"
            ;;
        real|sim)
            [[ -n $host ]] || { err "--$mode requires --host HOST[:PORT]"; return 1; }
            local pair edge_host edge_port
            pair=$(split_hostport "$host" "" "$GRPC_PORT") || return 1
            read -r edge_host edge_port <<<"$pair"
            [[ -n $edge_host ]] || { err "--$mode --host needs a host part"; return 1; }
            "run_$mode" "$model" "$edge_host" "$edge_port"
            ;;
        '')
            err "run: missing mode (--remote|--real|--sim)"; usage; return 1 ;;
    esac
}

case ${1:-} in
    -h|--help|help|'') usage ;;
    build) shift; cmd_build "$@" ;;
    run)   shift; cmd_run "$@" ;;
    *) err "unknown command: '$1'"; usage; exit 1 ;;
esac
