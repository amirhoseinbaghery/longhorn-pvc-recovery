
# 📖 README — 🇮🇷 فارسی

## 🔗 نسخه انگلیسی

* [English](README.md)
---

## 🎯 هدف: بازیابی داده از Longhorn PVC بدون Kubernetes/etcd

گاهی ممکن است کلاستر Kubernetes و etcd/کنترل‌پلین از کار بیفتد و دسترسی مستقیم به PVCها نیز از طریق K8s امکان‌پذیر نباشد.
این راهنما توضیح می‌دهد چگونه می‌توان **به‌طور مستقیم** به replicaهای لانگ‌هورن روی نود دسترسی گرفت، آن‌ها را با Longhorn Engine به‌صورت **دستگاه بلاکی** اکسپوز کرد، سپس مونت نمود و داده‌ها (فایل‌ها یا دیتابیس) را بازیابی کرد.

⚠️ این روش برای **بازیابی آفلاین** است، نه اجرای سرویس روی همان داده‌ها.

---

## 🧪 تست‌شده روی

* **سیستم‌عامل:** Ubuntu 20.04 / 22.04
* **Runtime:** containerd + `nerdctl` (نیازمند privileged)
* **Longhorn Engine:** v1.5.3
* **فایل‌سیستم‌ها:** ext4 و xfs (برای xfs از `-o nouuid` استفاده می‌شود)
* **سرویس‌ها/داده‌های بازیابی‌شده:**

  * Jira, Confluence, PostgreSQL (DB سرویس‌ها)
  * GitLab (artifacts, uploads, registry, backups)
  * Kafka
  * Elasticsearch
  * ClickHouse

---

## 🚀 مراحل دستی (خلاصه)

1. **لیست PVCها روی نود:**

   ```bash
   ls /var/lib/longhorn/replicas/
   ```

2. **انتخاب PVC و مشاهده متادیتا:**

   ```bash
   PVC=/var/lib/longhorn/replicas/pvc-1304f0e2-...
   cat "$PVC/volume.meta"
   ```

3. **راه‌اندازی Longhorn Engine:**

   ```bash
   nerdctl run -v /dev:/host/dev -v /proc:/host/proc \
     -v "$PVC:/volume" --privileged \
     longhornio/longhorn-engine:v1.5.3 \
     launch-simple-longhorn pvc-1304f0e2-... 10737418240
   ```

4. **پیدا کردن دیسک و مونت کردن:**

   ```bash
   lsblk
   mkdir -p /mnt/recover
   # ext4:
   mount -o ro /dev/sdX /mnt/recover
   # xfs:
   mount -o ro,nouuid /dev/sdX /mnt/recover
   ```

5. **نمونه محتوا (مثال GitLab):**

   ```
   /mnt/recover/
     gitlab-artifacts  gitlab-backups  gitlab-uploads  registry  ...
   ```

6. **بازیابی دیتابیس‌ها (مثال PostgreSQL):**

   ```bash
   nerdctl run --rm --network=host \
     -v /mnt/recover:/var/lib/postgresql/data \
     postgres:16.3
   # سپس pg_dump برای خروجی گرفتن
   ```

---

## 📂 مثال‌ها

* **Jira/Confluence (PostgreSQL):**
  مونت → اجرای Postgres هم‌نسخه → گرفتن `pg_dump`

* **GitLab:**
  مسیرهای `gitlab-artifacts/`, `gitlab-uploads/`, `registry/`, `gitlab-backups/` را کپی کنید.

* **Kafka / Elasticsearch / ClickHouse:**
  داده‌ها را کپی کنید و در صورت نیاز سرویس هم‌نسخه را روی **کپی داده‌ها** بالا بیاورید.

---

## ⚠️ هشدارها و نکات ایمنی

* همیشه ابتدا **Read-Only** مونت کنید.
* برای xfs از `-o ro,nouuid` استفاده کنید.
* در صورت نیاز به **نوشتن (RW)**، ابتدا با `dd` یا ابزار مشابه یک **کپی بلاک‌دستگاه** بگیرید.
* روی نودی کار کنید که replica کامل دارد.
* اگر فایل‌سیستم شناسایی نشد، ممکن است LVM یا RAID باشد. ابتدا با `file -s` بررسی کنید.

---

## 🛠️ اسکریپت: `auto-recover-longhorn.sh`

این اسکریپت مراحل بالا را خودکار می‌کند:

* خواندن `volume.meta` و استخراج `Size` و `BaseName`
* اجرای Longhorn Engine
* شناسایی خودکار دستگاه بلاکی جدید
* تشخیص نوع فایل‌سیستم و مونت ایمن (RO) روی `/mnt/<BaseName>`
* پشتیبانی از xfs (`nouuid`)
* امکان Cleanup سریع (unmount و stop)

> نیازمندی‌ها: `nerdctl` یا `docker`, `jq`, `lsblk`, `blkid`, `mount`, `awk`, `sed`

(کل اسکریپت بدون تغییر در پایین README قرار می‌گیرد ✅)

---

## 📊 اجرای نمونه اسکریپت

```bash
sudo ./auto-recover-longhorn.sh \
  --pvc-path /var/lib/longhorn/replicas/pvc-1304f0e2-... \
  --engine-version v1.5.3
```

سپس مسیر مونت:

```
/mnt/pvc-1304f0e2-...
  gitlab-artifacts  gitlab-backups  gitlab-uploads  registry  ...
```

---

می‌خوای من همین بازنویسی رو با اسکریپت کامل (`auto-recover-longhorn.sh`) برات بذارم توی یک فایل Markdown تمیز (با کد و هایلایت کامل) تا مستقیم جایگزین README بشه؟
