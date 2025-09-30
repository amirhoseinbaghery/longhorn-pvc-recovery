#!/usr/bin/env bash
# auto-recover-longhorn.sh
# Recover/mount a Longhorn PVC replica as a block device and mount it safely (RO).
# Usage:
#   sudo ./auto-recover-longhorn.sh \
#     --pvc-path /var/lib/longhorn/replicas/pvc-...-XXXXXXXX \
#     --engine-version v1.5.3 \
#     [--runtime nerdctl|docker] [--rw] [--mount-base /mnt] [--fsck]

set -euo pipefail

err() { echo "[-] $*" >&2; }
ok()  { echo "[+] $*"; }
info(){ echo "[*] $*"; }

RUNTIME="${RUNTIME:-}"     # nerdctl|docker (auto-detect)
PVC_PATH=""
ENGINE_VER=""
MOUNT_BASE="/mnt"
READ_ONLY=1
DO_FSCK=0

usage() {
  cat <<EOF
Usage: $0 --pvc-path <replica_dir> --engine-version <vX.Y.Z> [options]

Required:
  --pvc-path         Path to Longhorn replica dir (e.g., /var/lib/longhorn/replicas/pvc-...-deadbeef)
  --engine-version   Longhorn engine image tag (e.g., v1.5.3)

Optional:
  --runtime <r>      Container runtime: nerdctl|docker (auto if omitted)
  --mount-base <d>   Base mount dir (default: /mnt)
  --rw               Mount read-write (DANGEROUS; default is read-only)
  --fsck             Run non-destructive fsck pass (-n) before mount
  -h|--help          Show this help

Example:
  sudo $0 --pvc-path /var/lib/longhorn/replicas/pvc-1304f0e2-...-e3f64f05 --engine-version v1.5.3
EOF
}

# --- parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pvc-path)        PVC_PATH="$2"; shift 2;;
    --engine-version)  ENGINE_VER="$2"; shift 2;;
    --runtime)         RUNTIME="$2"; shift 2;;
    --mount-base)      MOUNT_BASE="$2"; shift 2;;
    --rw)              READ_ONLY=0; shift;;
    --fsck)            DO_FSCK=1; shift;;
    -h|--help)         usage; exit 0;;
    *) err "Unknown arg: $1"; usage; exit 1;;
  esac
done

[[ $EUID -eq 0 ]] || { err "Run as root."; exit 1; }
[[ -n "$PVC_PATH" && -d "$PVC_PATH" ]] || { err "--pvc-path invalid"; exit 1; }
[[ -n "$ENGINE_VER" ]] || { err "--engine-version is required"; exit 1; }

# runtime
if [[ -z "$RUNTIME" ]]; then
  if command -v nerdctl >/dev/null 2>&1; then RUNTIME="nerdctl"
  elif command -v docker >/dev/null 2>&1; then RUNTIME="docker"
  else err "Need nerdctl or docker."; exit 1; fi
fi

for cmd in jq lsblk blkid awk sed mount; do
  command -v "$cmd" >/dev/null 2>&1 || { err "Missing dependency: $cmd"; exit 1; }
done

META="$PVC_PATH/volume.meta"
[[ -f "$META" ]] || { err "volume.meta not found at $META"; exit 1; }

SIZE="$(jq -r '.Size' "$META" 2>/dev/null || true)"
[[ "$SIZE" =~ ^[0-9]+$ ]] || { err "Invalid Size in $META"; exit 1; }

# BASE_NAME = PVC name without the last '-xxxxxxxx' suffix
# e.g. pvc-1304f0e2-0165-4030-8a10-c081393398b7-e3f64f05 -> pvc-1304f0e2-0165-4030-8a10-c081393398b7
PVC_DIRNAME="$(basename "$PVC_PATH")"
BASE_NAME="$(echo "$PVC_DIRNAME" | sed -E 's/-[0-9a-fA-F]{8}$//')"

ok "PVC path: $PVC_PATH"
ok "Base name: $BASE_NAME"
ok "Size: $SIZE"
ok "Runtime: $RUNTIME"
ok "Engine: longhornio/longhorn-engine:$ENGINE_VER"

# record devices before
before_devs="$(lsblk -dn -o NAME | sort)"
CONTAINER_NAME="lh-$BASE_NAME-$$"

info "Launching Longhorn Engine container..."
set +e
$RUNTIME run -d --name "$CONTAINER_NAME" \
  -v /dev:/host/dev -v /proc:/host/proc \
  -v "$PVC_PATH":/volume \
  --privileged "longhornio/longhorn-engine:$ENGINE_VER" \
  launch-simple-longhorn "$BASE_NAME" "$SIZE" >/dev/null
rc=$?
set -e
[[ $rc -eq 0 ]] || { err "Failed to start engine container"; exit 1; }

cleanup() {
  info "Cleanup: attempting unmount/stop..."
  mountpoint -q "$MNT_DIR" && umount "$MNT_DIR" || true
  $RUNTIME rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

info "Waiting for new block device to appear..."
for i in {1..20}; do
  sleep 0.5
  after_devs="$(lsblk -dn -o NAME | sort)"
  NEW_DEV="$(comm -13 <(echo "$before_devs") <(echo "$after_devs") | head -n1 || true)"
  [[ -n "$NEW_DEV" ]] && break
done

[[ -n "$NEW_DEV" ]] || { err "No new block device detected."; exit 1; }
DEV_PATH="/dev/$NEW_DEV"
ok "Detected device: $DEV_PATH"

FSTYPE="$(blkid -o value -s TYPE "$DEV_PATH" 2>/dev/null || true)"
if [[ -z "$FSTYPE" ]]; then
  info "Filesystem type not detected via blkid; probing with 'file -s'..."
  if command -v file >/dev/null 2>&1; then
    file -s "$DEV_PATH" || true
  fi
fi
[[ -n "$FSTYPE" ]] && ok "Filesystem: $FSTYPE" || info "Filesystem unknown (may be LVM/RAW/other)."

MNT_DIR="$MOUNT_BASE/$BASE_NAME"
mkdir -p "$MNT_DIR"

if [[ $DO_FSCK -eq 1 && -n "$FSTYPE" ]]; then
  info "Running non-destructive fsck (-n)..."
  case "$FSTYPE" in
    ext*) fsck.ext4 -n "$DEV_PATH" || true ;;
    xfs)  xfs_repair -n "$DEV_PATH" || true ;;
    *)    info "fsck not configured for $FSTYPE";;
  esac
fi

info "Mounting safely..."
if [[ $READ_ONLY -eq 1 ]]; then
  if [[ "$FSTYPE" == xfs ]]; then
    mount -o ro,nouuid "$DEV_PATH" "$MNT_DIR"
  else
    mount -o ro "$DEV_PATH" "$MNT_DIR"
  fi
else
  err "WARNING: mounting READ-WRITE. Consider working on a block-level copy!"
  if [[ "$FSTYPE" == xfs ]]; then
    mount -o nouuid "$DEV_PATH" "$MNT_DIR"
  else
    mount "$DEV_PATH" "$MNT_DIR"
  fi
fi

ok "Mounted at: $MNT_DIR"
echo
echo "Contents:"
ls -lah "$MNT_DIR" | sed -n '1,80p'
echo
ok "To unmount: umount '$MNT_DIR'"
ok "To stop engine: $RUNTIME rm -f '$CONTAINER_NAME'"
echo
