# Longhorn PVC Recovery Guide

## README — English

Recover data from **Longhorn PVC replicas** when Kubernetes/etcd is down. You will expose a replica as a **block device** with **Longhorn Engine**, mount it safely, then copy or export your data (files or DBs).

---

## 📂 Additional

* [Persian](README.fa.md)

---

## ✅ Tested on

* **OS:** Debian 11/12 (also works on Ubuntu 20.04/22.04)
* **Runtime:** containerd with `nerdctl` (Docker works too)
* **Longhorn Engine:** v1.5.3
* **Filesystems:** ext4, xfs (handled with `-o nouuid` when needed)
* **Recovered from:** Jira / Confluence (PostgreSQL), Kafka, GitLab (artifacts/uploads/registry/backups), Elasticsearch, ClickHouse

> ⚠️ This is for **offline recovery**. Do **not** run production workloads on the mounted data.

---

## 🔧 Prerequisites

* Root access to the node holding the Longhorn replica(s)
* Tools: `jq`, `lsblk`, `blkid`, `mount` (and `xfs_repair` for xfs)
* Container runtime: `nerdctl` (or `docker`) with `--privileged`
* The **Longhorn Engine image** matching your Longhorn version

  * Tip: find it via `nerdctl images | grep longhorn-engine` or `ctr -n k8s.io images ls | grep longhorn-engine`

---

## ⚡ Quick Start (one-liner-ish)

```bash
PVC_DIR="/var/lib/longhorn/replicas/<PVC_NAME-with-last-suffix>"
SIZE=$(jq -r .Size "$PVC_DIR/volume.meta")
BASE=$(basename "$PVC_DIR" | sed -E 's/-[0-9a-fA-F]{8}$//')
nerdctl run -d --name "lh-$BASE" \
  -v /dev:/host/dev -v /proc:/host/proc -v "$PVC_DIR":/volume \
  --privileged longhornio/longhorn-engine:v1.5.3 \
  launch-simple-longhorn "$BASE" "$SIZE"
sleep 2
lsblk
# mount the new /dev/sdX read-only to /mnt/$BASE (see details below)
```

---

## 🧭 Detailed Steps (Manual)

### 1) List PVC replicas

```bash
ls /var/lib/longhorn/replicas/
```

### 2) Inspect metadata

```bash
PVC=/var/lib/longhorn/replicas/pvc-1304f0e2-0165-4030-8a10-c081393398b7-e3f64f05
cat "$PVC/volume.meta"
# {"Size":10737418240,"Head":"volume-head-001.img","Dirty":true,"Parent":"volume-snap-7dd5...","SectorSize":512,...}
```

### 3) Start Longhorn Engine (placeholders explained)

```bash
nerdctl run -v /dev:/host/dev -v /proc:/host/proc \
  -v /var/lib/longhorn/replicas/pvc-1304f0e2-0165-4030-8a10-c081393398b7-e3f64f05:/volume \
  --privileged longhornio/longhorn-engine:v1.5.3 \
  launch-simple-longhorn pvc-1304f0e2-0165-4030-8a10-c081393398b7 10737418240
```

**What to put where:**

* `-v /var/lib/longhorn/replicas/<PVC_NAME-with-last-suffix>:/volume`
  Path to the **replica directory** you want to recover. Example here:
  `pvc-1304f0e2-0165-4030-8a10-c081393398b7-e3f64f05`.

* `longhornio/longhorn-engine:v1.5.3`
  Use the **same engine version** as your Longhorn installation.

* `launch-simple-longhorn <PVC_BASE_NAME> <PVC_SIZE_BYTES>`

  * `<PVC_BASE_NAME>` = the replica directory **without the final `-XXXXXXXX` suffix**.
    From `pvc-...-e3f64f05` → `pvc-1304f0e2-0165-4030-8a10-c081393398b7`.
    You can derive it with:

    ```bash
    basename "$PVC" | sed -E 's/-[0-9a-fA-F]{8}$//'
    ```
  * `<PVC_SIZE_BYTES>` = the `Size` field in `volume.meta` (in **bytes**).
    Example above: `10737418240`. Extract with:

    ```bash
    jq -r .Size "$PVC/volume.meta"
    ```

> After the container starts, a new block device appears (e.g., `/dev/sdf`).

### 4) Find the new device

```bash
lsblk
# If you see partitions (e.g., /dev/sdf1), mount the partition, not the disk.
```

### 5) Mount safely (read-only recommended)

```bash
MNT="/mnt/$(basename "$PVC" | sed -E 's/-[0-9a-fA-F]{8}$//')"
mkdir -p "$MNT"

# ext4 (read-only):
mount -o ro /dev/sdX "$MNT"

# xfs (read-only + avoid UUID clash):
# mount -o ro,nouuid /dev/sdX "$MNT"

ls -lah "$MNT"
```

> If `blkid /dev/sdX` shows no FS type, check `fdisk -l /dev/sdX` (maybe partitions exist) or `file -s /dev/sdX`.

---

## 🧪 Worked Example

* **Replica dir:**
  `/var/lib/longhorn/replicas/pvc-1304f0e2-0165-4030-8a10-c081393398b7-e3f64f05`
* **`volume.meta` Size:** `10737418240`
* **Base name:** `pvc-1304f0e2-0165-4030-8a10-c081393398b7`

Commands:

```bash
PVC=/var/lib/longhorn/replicas/pvc-1304f0e2-0165-4030-8a10-c081393398b7-e3f64f05
SIZE=$(jq -r .Size "$PVC/volume.meta")
BASE=$(basename "$PVC" | sed -E 's/-[0-9a-fA-F]{8}$//')

nerdctl run -d --name "lh-$BASE" \
  -v /dev:/host/dev -v /proc:/host/proc -v "$PVC":/volume \
  --privileged longhornio/longhorn-engine:v1.5.3 \
  launch-simple-longhorn "$BASE" "$SIZE"

sleep 2
lsblk   # e.g. /dev/sdf
mkdir -p "/mnt/$BASE"
mount -o ro /dev/sdf "/mnt/$BASE"   # or -o ro,nouuid for xfs
ls "/mnt/$BASE"
```

Example output might contain:

```
gitlab-artifacts  gitlab-backups  gitlab-uploads  registry  ...
```

---

## 🗃️ Databases

* **PostgreSQL (Jira/Confluence/GitLab):**

  ```bash
  nerdctl run --rm --network=host \
    -v /mnt/<BASE>:/var/lib/postgresql/data \
    postgres:16.3
  pg_dump -U <user> -h localhost -p 5432 <db> > backup.sql
  ```

* **Elasticsearch / ClickHouse / Kafka:**
  Prefer same-version containers, mount recovered data **read-only**, and export/snapshot.
  For Elasticsearch, snapshots are safer than raw-file reuse.

---

## 🧹 Cleanup

```bash
umount /mnt/<BASE>
nerdctl rm -f "lh-<BASE>"
# (or docker rm -f "lh-<BASE>")
```

---

## 🆘 Troubleshooting

* **No new block device appears:**
  Ensure `--privileged`, check `dmesg`, confirm the replica path is correct, try another node/replica.

* **“wrong fs type / bad superblock”:**
  Try the correct partition (e.g., `/dev/sdX1`). For xfs use `-o ro,nouuid`. Optionally run non-destructive checks:

  ```bash
  fsck.ext4 -n /dev/sdX
  xfs_repair -n /dev/sdX
  ```

* **“device is busy” on unmount:**
  `lsof +f -- /mnt/<BASE>` or `fuser -vm /mnt/<BASE>` then stop processes, retry unmount.

* **Need Docker instead of nerdctl:**
  Replace `nerdctl run ...` with:

  ```bash
  docker run -d --name "lh-$BASE" \
    -v /dev:/host/dev -v /proc:/host/proc -v "$PVC":/volume \
    --privileged longhornio/longhorn-engine:v1.5.3 \
    launch-simple-longhorn "$BASE" "$SIZE"
  ```

---

## 🛠️ Script (Optional)

See `auto-recover-longhorn.sh` for full automation: it reads `volume.meta`, launches the engine, detects the new device, and mounts it safely under `/mnt/<BASE>` (handles xfs `nouuid`). Usage:

```bash
sudo ./auto-recover-longhorn.sh \
  --pvc-path /var/lib/longhorn/replicas/pvc-1304f0e2-...-e3f64f05 \
  --engine-version v1.5.3
```
