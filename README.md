# README — English

## Recovering Data from Longhorn PVCs when Kubernetes/etcd is Down

**Scenario:** Your Kubernetes cluster is completely broken (e.g., etcd/control-plane failure) and you cannot access PersistentVolumeClaims (PVCs) via Kubernetes.
With this method, you can directly access **Longhorn replicas** on the node, expose them as block devices using **Longhorn Engine**, mount them, and recover your data (files or databases).

---

## ✅ Tested on

* **OS:** Ubuntu 20.04 / 22.04
* **Runtime:** containerd with `nerdctl` (works with Docker too)
* **Longhorn Engine:** v1.5.3
* **Filesystems:** ext4 and xfs (script handles `xfs` with `-o nouuid`)
* **Successfully recovered data from:**

  * Jira / Confluence (PostgreSQL DB)
  * Kafka
  * GitLab (artifacts, uploads, registry, backups, etc.)
  * Elasticsearch
  * ClickHouse

> ⚠️ Note: This method is for **offline recovery only**. Do not use the mounted PVC for production workloads.

---

## Recovery Steps (Manual)

1. **List PVC replicas** on your node:

   ```bash
   ls /var/lib/longhorn/replicas/
   ```

2. **Inspect metadata** of the chosen PVC:

   ```bash
   PVC=/var/lib/longhorn/replicas/pvc-1304f0e2-0165-4030-8a10-c081393398b7-e3f64f05
   cat "$PVC/volume.meta"
   # Example output:
   # {"Size":10737418240,"Head":"volume-head-001.img","Dirty":true,"Parent":"volume-snap-7dd54e7f-400d-4733-bba0-ee1dc7e13425.img", ...}
   ```

3. **Start Longhorn Engine** to expose the PVC as a block device:

   ```bash
   nerdctl run -v /dev:/host/dev -v /proc:/host/proc \
     -v /var/lib/longhorn/replicas/pvc-1304f0e2-...-e3f64f05:/volume \
     --privileged longhornio/longhorn-engine:v1.5.3 \
     launch-simple-longhorn pvc-1304f0e2-0165-4030-8a10-c081393398b7 10737418240
   ```

4. **Find the new device**:

   ```bash
   lsblk
   # Example: /dev/sdf appears
   ```

5. **Mount it safely (read-only recommended):**

   ```bash
   mkdir -p /mnt/recover
   # ext4:
   mount -o ro /dev/sdf /mnt/recover
   # xfs:
   mount -o ro,nouuid /dev/sdf /mnt/recover
   ```

6. **Explore your data**:

   ```
   /mnt/recover/
     gitlab-artifacts  gitlab-backups  gitlab-uploads  registry  ...
   ```

7. **For databases:**

   * **PostgreSQL (e.g., Jira/Confluence/GitLab DB):**

     ```bash
     nerdctl run --rm --network=host \
       -v /mnt/recover:/var/lib/postgresql/data \
       postgres:16.3
     ```

     Then connect locally and `pg_dump`:

     ```bash
     pg_dump -U <user> -h localhost -p 5432 <db> > backup.sql
     ```

   * **Elasticsearch / ClickHouse / Kafka:**
     Use a container with the same version, mount the recovered data **read-only**, and export data or copy raw files.

---

## Example Recoveries

* **Jira / Confluence DB (PostgreSQL):**
  Mount PVC → Run same Postgres version → Dump with `pg_dump`.

* **GitLab (shared storage + registry):**
  Copy directories like `gitlab-artifacts/`, `gitlab-uploads/`, `registry/`, `gitlab-backups/`.

* **Kafka:**
  Copy log directories, or run broker with the same version on the copied data.

* **Elasticsearch:**
  Use only for raw file recovery; for production use snapshots instead.

* **ClickHouse:**
  Copy table directories (`store/` and `metadata/`), then attach them to a new CH instance.

---

## ⚠️ Safety Notes

* Always mount PVCs **read-only** unless absolutely necessary.
* For xfs, use `-o nouuid`.
* If unsure, make a **block-level copy** with `dd` before mounting:

  ```bash
  dd if=/dev/sdX of=/path/to/backup.img bs=1M status=progress
  ```
* Some replicas may be “Dirty:true”. Longhorn Engine handles recovery automatically.
* If filesystem not detected, check with:

  ```bash
  file -s /dev/sdX
  ```

---

## 🛠️ Script — `auto-recover-longhorn.sh`

This script automates the manual steps:

* Reads `volume.meta` and extracts size & base name
* Launches Longhorn Engine container
* Detects the new block device automatically
* Determines filesystem type and mounts it **safely (read-only)** under `/mnt/<PVC_NAME>`
* Handles xfs (`-o nouuid`)
* Optional: run `fsck` in non-destructive mode (`-n`)
* Provides cleanup commands (umount, stop container)

Usage example:

```bash
sudo ./auto-recover-longhorn.sh \
  --pvc-path /var/lib/longhorn/replicas/pvc-1304f0e2-...-e3f64f05 \
  --engine-version v1.5.3
```

Result:

```
Mounted at: /mnt/pvc-1304f0e2-0165-4030-8a10-c081393398b7
Contents:
  gitlab-artifacts  gitlab-backups  gitlab-uploads  registry  ...
```
