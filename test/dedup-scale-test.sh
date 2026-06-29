#!/usr/bin/env bash
# Scale test for crio storage dedup (OCPNODE-4588).
#
# Builds NUM_IMAGES container images with:
#   - varied per-image sizes (unique random layer)
#   - duplicated content across images (shared blob files copied into separate layers)
#
# Then runs `crio dedup`, records wall time, disk usage, and bytes saved.
#
# Prerequisites: podman, XFS graphroot with reflink=1, built ./bin/crio, /etc/crio/crio.conf
#
# Usage:
#   export GRAPHROOT=/var/tmp/crio-storage/graphroot
#   export RUNROOT=/var/tmp/crio-storage/runroot
#   sudo -E ./test/dedup-scale-test.sh
#
# Options (env):
#   NUM_IMAGES=100          number of images to build (default: 100)
#   SKIP_BUILD=1            skip image build, only run dedup (storage already populated)
#   CRIO_BIN=./bin/crio
#   CRIO_CONF=/etc/crio/crio.conf
#   RESULTS_FILE=/tmp/dedup-scale-results.txt

set -euo pipefail

NUM_IMAGES="${NUM_IMAGES:-100}"
GRAPHROOT="${GRAPHROOT:-/var/tmp/crio-storage/graphroot}"
RUNROOT="${RUNROOT:-/var/tmp/crio-storage/runroot}"
CRIO_BIN="${CRIO_BIN:-./bin/crio}"
CRIO_CONF="${CRIO_CONF:-/etc/crio/crio.conf}"
RESULTS_FILE="${RESULTS_FILE:-/tmp/dedup-scale-results.txt}"
SKIP_BUILD="${SKIP_BUILD:-0}"

PODMAN=(podman --root "$GRAPHROOT" --runroot "$RUNROOT" --storage-driver overlay)

log() {
	echo "[$(date -Iseconds)] $*" >&2
}

require_root() {
	if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
		echo "Run as root (sudo -E $0)" >&2
		exit 1
	fi
}

check_reflink() {
	local mountpoint
	mountpoint=$(findmnt -n -o TARGET --target "$GRAPHROOT" 2>/dev/null || true)
	if [[ -z "$mountpoint" ]]; then
		log "WARN: could not determine mount for $GRAPHROOT"
		return
	fi
	if command -v xfs_info >/dev/null 2>&1; then
		if ! xfs_info "$mountpoint" 2>/dev/null | grep -q 'reflink=1'; then
			log "WARN: $mountpoint may not have XFS reflink=1; dedup may report no savings"
		fi
	else
		log "WARN: xfs_info not found; assuming reflink is configured"
	fi
}

du_graphroot() {
	du -sb "$GRAPHROOT" 2>/dev/null | awk '{print $1}'
}

human_bytes() {
	numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || echo "${1} bytes"
}

prepare_shared_blobs() {
	local workdir=$1
	local shared_dir="$workdir/shared-blobs"
	mkdir -p "$shared_dir"

	# Shared files reused across many images (simulates common base layers / JARs / model weights).
	# Total ~118 MB of shared content; each image copies 3–4 of these into its own layer.
	local sizes_mb=(1 2 5 10 10 20 20 50)
	local i=0
	for size in "${sizes_mb[@]}"; do
		local f="$shared_dir/shared-$(printf '%02d' "$i")-${size}mb.dat"
		if [[ ! -f "$f" ]]; then
			log "Creating shared blob $(basename "$f")"
			dd if=/dev/urandom of="$f" bs=1M count="$size" status=none
		fi
		i=$((i + 1))
	done

	echo "$shared_dir"
}

build_images() {
	local workdir=$1
	local shared_dir=$2
	local build_start build_end build_secs

	log "Building $NUM_IMAGES images into $GRAPHROOT (this may take a while)..."

	# Pull base once
	"${PODMAN[@]}" pull docker.io/library/alpine:3.19

	build_start=$(date +%s)

	for n in $(seq 1 "$NUM_IMAGES"); do
		local tag="localhost/dedup-scale-$(printf '%03d' "$n"):latest"
		local ctx="$workdir/build-$n"
		mkdir -p "$ctx"

		# Pick 3 shared blobs with overlap across images (every image shares at least 2 with neighbors).
		local b0=$(( (n - 1) % 8 ))
		local b1=$(( (n + 2) % 8 ))
		local b2=$(( (n + 5) % 8 ))
		local blobs=("$shared_dir"/shared-$(printf '%02d' "$b0")-* \
			"$shared_dir"/shared-$(printf '%02d' "$b1")-* \
			"$shared_dir"/shared-$(printf '%02d' "$b2")-*)

		# Unique layer size: 1–15 MB depending on image index (variety of sizes).
		local unique_mb=$(( (n % 15) + 1 ))
		dd if=/dev/urandom of="$ctx/unique.dat" bs=1M count="$unique_mb" status=none

		{
			echo 'FROM alpine:3.19'
			for blob in "${blobs[@]}"; do
				echo "COPY $(basename "$blob") /shared/$(basename "$blob")"
				cp "$blob" "$ctx/"
			done
			echo 'COPY unique.dat /app/unique.dat'
			echo "RUN echo dedup-scale-$n > /app/id.txt"
		} >"$ctx/Dockerfile"

		if ! "${PODMAN[@]}" build -q -t "$tag" "$ctx" >/dev/null; then
			log "ERROR: build failed for $tag"
			exit 1
		fi

		if (( n % 10 == 0 )); then
			log "Built $n / $NUM_IMAGES images..."
		fi
	done

	build_end=$(date +%s)
	build_secs=$((build_end - build_start))
	log "Image build complete in ${build_secs}s ($(( build_secs / 60 ))m $(( build_secs % 60 ))s)"
	echo "$build_secs"
}

run_dedup() {
	local dedup_log=$1
	local start end elapsed

	log "Running crio dedup..."
	start=$(date +%s)
	"$CRIO_BIN" -c "$CRIO_CONF" dedup 2>&1 | tee "$dedup_log"
	end=$(date +%s)
	elapsed=$((end - start))
	log "Dedup finished in ${elapsed}s"
	echo "$elapsed"
}

parse_saved_bytes() {
	local dedup_log=$1
	# "Storage deduplication complete: 20MiB saved" or "no savings"
	if grep -q 'no savings' "$dedup_log"; then
		echo 0
	elif grep -oE '[0-9]+(\.[0-9]+)?[[:space:]]*[KMGT]?iB saved' "$dedup_log" >/dev/null; then
		grep -oE 'Storage deduplication complete: [^$]+' "$dedup_log" | tail -1
	else
		echo "unknown"
	fi
}

main() {
	require_root
	check_reflink

	if [[ ! -x "$CRIO_BIN" ]]; then
		echo "CRI-O binary not found: $CRIO_BIN" >&2
		exit 1
	fi

	local workdir
	workdir=$(mktemp -d)
	trap 'rm -rf "$workdir"' EXIT

	local build_secs=0
	if [[ "$SKIP_BUILD" != "1" ]]; then
		local shared_dir
		shared_dir=$(prepare_shared_blobs "$workdir")
		build_secs=$(build_images "$workdir" "$shared_dir")
	else
		log "SKIP_BUILD=1: using existing storage"
	fi

	local image_count
	image_count=$("${PODMAN[@]}" images -q 2>/dev/null | wc -l | tr -d ' ')
	local before_bytes after_bytes
	before_bytes=$(du_graphroot)

	log "Storage before dedup: $(human_bytes "$before_bytes") ($before_bytes bytes)"
	log "Images in store: $image_count"

	local dedup_log="$workdir/dedup.log"
	local dedup_secs
	dedup_secs=$(run_dedup "$dedup_log")

	after_bytes=$(du_graphroot)
	local delta=$((before_bytes - after_bytes))
	local saved_line
	saved_line=$(parse_saved_bytes "$dedup_log")

	{
		echo "=============================================="
		echo "CRI-O storage dedup scale test results"
		echo "Date: $(date -Iseconds)"
		echo "Host: $(hostname)"
		echo "NUM_IMAGES (requested): $NUM_IMAGES"
		echo "Images in store: $image_count"
		echo "GRAPHROOT: $GRAPHROOT"
		echo "----------------------------------------------"
		echo "Build time: ${build_secs}s"
		echo "Dedup wall time: ${dedup_secs}s"
		echo "Disk before dedup: $(human_bytes "$before_bytes") ($before_bytes bytes)"
		echo "Disk after dedup:  $(human_bytes "$after_bytes") ($after_bytes bytes)"
		echo "du delta (before-after): $(human_bytes "$delta") ($delta bytes)"
		echo "crio dedup reported: $saved_line"
		echo "----------------------------------------------"
		echo "Notes:"
		echo "- Shared blobs simulate duplicated base content across images."
		echo "- Unique layer sizes vary 1-15 MB per image."
		echo "- Compare dedup wall time vs Palantir 10-min boot SLA separately on SNO."
		echo "=============================================="
	} | tee "$RESULTS_FILE"

	log "Results written to $RESULTS_FILE"
}

main "$@"
