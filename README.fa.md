# 📖 راهنمای بازیابی PVC لانگ‌هورن

**README — فارسی**
* [ٍEnglish](README.md)
## 🎯 هدف

بازیابی داده از **Replicaهای PVC لانگ‌هورن** وقتی که Kubernetes / etcd در دسترس نیست.
در این حالت شما یک replica را با **Longhorn Engine** به‌صورت دستگاه بلاکی اکسپوز می‌کنید، آن را به شکل ایمن (Read-Only) مونت کرده و سپس داده‌ها (فایل یا دیتابیس) را کپی یا خروجی می‌گیرید.

⚠️ **این روش صرفاً برای بازیابی آفلاین است. داده‌های مونت‌شده نباید برای اجرای بارهای کاری Production استفاده شوند.**

---

## ✅ تست‌شده روی

* **سیستم‌عامل‌ها:** Debian 11/12 (روی Ubuntu 20.04/22.04 هم کار می‌کند)
* **Runtime:** containerd همراه با `nerdctl` (Docker هم قابل استفاده است)
* **Longhorn Engine:** نسخه‌ی v1.5.3
* **فایل‌سیستم‌ها:** ext4 و xfs (برای xfs باید از `-o nouuid` استفاده شود)
* **سرویس‌های بازیابی‌شده:**

  * Jira / Confluence (PostgreSQL)
  * Kafka
  * GitLab (artifacts, uploads, registry, backups)
  * Elasticsearch
  * ClickHouse

---

## 🔧 پیش‌نیازها

* دسترسی root روی نودی که replicaهای لانگ‌هورن روی آن قرار دارند
* ابزارهای: `jq`, `lsblk`, `blkid`, `mount` (و برای xfs: ابزار `xfs_repair`)
* Container runtime: `nerdctl` یا `docker` همراه با `--privileged`
* ایمیج Longhorn Engine هم‌نسخه با نصب شما

💡 برای پیدا کردن نسخه‌ی ایمیج:

```bash
nerdctl images | grep longhorn-engine
# یا
ctr -n k8s.io images ls | grep longhorn-engine
```

---

## ⚡ شروع سریع (تقریباً یک خطی)

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
# سپس /dev/sdX جدید را فقط خواندنی مونت کنید روی /mnt/$BASE
```

---

## 🧭 مراحل دستی (گام‌به‌گام)

1. **لیست گرفتن از PVCها**

   ```bash
   ls /var/lib/longhorn/replicas/
   ```

2. **مشاهده متادیتا**

   ```bash
   PVC=/var/lib/longhorn/replicas/pvc-1304f0e2-...-e3f64f05
   cat "$PVC/volume.meta"
   # {"Size":10737418240,"Head":"volume-head-001.img","Dirty":true,...}
   ```

3. **اجرای Longhorn Engine**

   ```bash
   nerdctl run -v /dev:/host/dev -v /proc:/host/proc \
     -v "$PVC":/volume \
     --privileged longhornio/longhorn-engine:v1.5.3 \
     launch-simple-longhorn <PVC_BASE_NAME> <PVC_SIZE_BYTES>
   ```

   * `<PVC_BASE_NAME>` = نام پوشه بدون پسوند آخر `-XXXXXXXX`
   * `<PVC_SIZE_BYTES>` = عدد موجود در `volume.meta` → فیلد `Size` (بر حسب بایت)

4. **پیدا کردن دستگاه بلاکی جدید**

   ```bash
   lsblk
   # اگر پارتیشن داشت (مثلاً /dev/sdf1)، همان پارتیشن را مونت کنید.
   ```

5. **مونت ایمن (Read-Only)**

   ```bash
   MNT="/mnt/<PVC_BASE_NAME>"
   mkdir -p "$MNT"

   # ext4
   mount -o ro /dev/sdX "$MNT"

   # xfs
   mount -o ro,nouuid /dev/sdX "$MNT"
   ```

   اگر `blkid` هیچ فایل‌سیستمی نشان نداد، با `fdisk -l /dev/sdX` یا `file -s /dev/sdX` بررسی کنید.

---

## 🧪 مثال عملی

* Replica: `/var/lib/longhorn/replicas/pvc-1304f0e2-...-e3f64f05`
* Size: `10737418240`
* Base name: `pvc-1304f0e2-0165-4030-8a10-c081393398b7`

دستورات:

```bash
PVC=/var/lib/longhorn/replicas/pvc-1304f0e2-...-e3f64f05
SIZE=$(jq -r .Size "$PVC/volume.meta")
BASE=$(basename "$PVC" | sed -E 's/-[0-9a-fA-F]{8}$//')

nerdctl run -d --name "lh-$BASE" \
  -v /dev:/host/dev -v /proc:/host/proc -v "$PVC":/volume \
  --privileged longhornio/longhorn-engine:v1.5.3 \
  launch-simple-longhorn "$BASE" "$SIZE"

sleep 2
lsblk   # مثلاً /dev/sdf
mkdir -p "/mnt/$BASE"
mount -o ro /dev/sdf "/mnt/$BASE"
ls "/mnt/$BASE"
```

📂 خروجی نمونه:

```
gitlab-artifacts  gitlab-backups  gitlab-uploads  registry  ...
```

---

## 🗃️ دیتابیس‌ها

* **PostgreSQL (Jira / Confluence / GitLab):**

  ```bash
  nerdctl run --rm --network=host \
    -v /mnt/<BASE>:/var/lib/postgresql/data \
    postgres:16.3

  pg_dump -U <user> -h localhost -p 5432 <db> > backup.sql
  ```

* **Elasticsearch / ClickHouse / Kafka:**
  ترجیحاً با همان نسخه‌ی سرویس، روی داده‌های **Read-Only** بالا آورده و snapshot/export بگیرید.
  (برای Elasticsearch استفاده از snapshot امن‌تر از استفاده مستقیم از فایل‌ها است.)

---

## 🧹 پاک‌سازی

```bash
umount /mnt/<BASE>
nerdctl rm -f "lh-<BASE>"
# یا docker rm -f "lh-<BASE>"
```

---

## 🆘 رفع اشکال

* **هیچ دستگاه جدیدی ظاهر نشد:**
  مطمئن شوید از `--privileged` استفاده کرده‌اید، لاگ‌های `dmesg` را بررسی کنید، مسیر replica را چک کنید یا روی نود دیگری تست کنید.

* **خطای فایل‌سیستم (wrong fs type / bad superblock):**
  پارتیشن درست (`/dev/sdX1`) را امتحان کنید. برای xfs حتماً `-o ro,nouuid` بگذارید.

  بررسی غیرمخرب:

  ```bash
  fsck.ext4 -n /dev/sdX
  xfs_repair -n /dev/sdX
  ```

* **خطای busy هنگام unmount:**

  ```bash
  lsof +f -- /mnt/<BASE>
  fuser -vm /mnt/<BASE>
  ```

* **نیاز به Docker به‌جای nerdctl:**

  ```bash
  docker run -d --name "lh-$BASE" \
    -v /dev:/host/dev -v /proc:/host/proc -v "$PVC":/volume \
    --privileged longhornio/longhorn-engine:v1.5.3 \
    launch-simple-longhorn "$BASE" "$SIZE"
  ```

---

## 🛠️ اسکریپت (اختیاری)

برای اتوماسیون کامل می‌توانید از `auto-recover-longhorn.sh` استفاده کنید.
این اسکریپت:

* `volume.meta` را می‌خواند
* Engine را بالا می‌آورد
* دستگاه جدید را شناسایی می‌کند
* آن را به صورت ایمن (با پشتیبانی از xfs `nouuid`) زیر `/mnt/<BASE>` مونت می‌کند

مثال اجرا:

```bash
sudo ./auto-recover-longhorn.sh \
  --pvc-path /var/lib/longhorn/replicas/pvc-1304f0e2-...-e3f64f05 \
  --engine-version v1.5.3
```

---

می‌خوای من همین ترجمه رو در قالب یک فایل Markdown آماده کنم (با تیترها و بلوک‌های کد تمیز) تا مستقیم جایگزین README فارسی بشه؟
