🚀 Masoud SSH Tunnel Manager

مدیریت پیشرفته SSH Tunnel و فوروارد پورت برای VMess TCP و Xray

🇬🇧 English

A powerful and interactive Bash-based SSH tunnel manager for advanced port forwarding over SSH.

Designed for stability, automation, and high-load environments.

## 🚀 Quick Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/masooooood/Masoud-SSH-Tunnel/main/masoud-ssh-tunnel.sh)
```

---


بعد از نصب: 

```
masoud-ssh
```

---


✨ Features

🔹 Support for single ports and port ranges (e.g. 60000-60070)

🔹 Support for mixed inputs (60000-60070,20000,2088)

🔹 Custom SSH port support (22 / 2222 / 443 / etc.)

🔹 Each tunnel runs as independent systemd service

🔹 Built-in connection monitoring

🔹 Auto-restart using autossh

🔹 Tunnel edit & auto-reload

🔹 Backup & Restore support

🔹 Full uninstall option

🔹 Clean interactive CLI interface

🔹 Lightweight and optimized

📦 Tunnel Capabilities

Mode	Description
Port Forwarding	Forward single ports or port ranges via SSH
Multi-Tunnel	Create unlimited independent SSH tunnels
Monitoring	View tunnel status and active connections

🔐 SSH Flexibility

✔ Custom SSH port per tunnel
✔ Key-based authentication
✔ Automatic reconnection
✔ Connection test built-in

🇮🇷 فارسی

یک اسکریپت قدرتمند و تعاملی مبتنی بر Bash برای مدیریت حرفه‌ای SSH Tunnel و فوروارد پورت.

مناسب برای:

VMess TCP

Xray

x-ui

انتقال ترافیک بدون TLS

تقسیم فشار روی چند سرویس SSH

✨ امکانات

🔹 پشتیبانی از پورت تکی و رنج پورت (مثلاً 60000-60070)

🔹 پشتیبانی از ورودی ترکیبی (60000-60070,20000,2088)

🔹 امکان تعیین پورت SSH دلخواه (مثلاً 22 یا 2222 یا 443)

🔹 هر تانل یک سرویس مستقل systemd

🔹 مانیتور تعداد کانکشن فعال

🔹 ریستارت خودکار با autossh

🔹 ویرایش تانل با ریستارت خودکار

🔹 امکان بکاپ و ریستور

🔹 حذف کامل اسکریپت و سرویس‌ها

🔹 محیط کاربری مرحله‌ای و تمیز

🔹 سبک و مناسب سرورهای پرترافیک

📦 قابلیت‌های تانل

حالت	توضیح
Port Forwarding	فوروارد پورت تکی یا رنج پورت از طریق SSH
Multi-Tunnel	ساخت تانل‌های نامحدود و مستقل
Monitoring	مشاهده وضعیت و تعداد اتصال فعال

🔐 انعطاف SSH

✔ امکان استفاده از پورت SSH دلخواه

✔ احراز هویت کلیدی (Key-Based)

✔ اتصال مجدد خودکار در صورت قطع شدن

✔ تست اتصال داخلی

🛠 Requirements

Ubuntu / Debian

Root access

Internet access

SSH access to remote server
