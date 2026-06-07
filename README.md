[![GitHub](https://img.shields.io/badge/GitHub-sosaramosalexis/deb-sleepwithme-181717?logo=github)](https://github.com/sosaramosalexis/deb-sleepwithme)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Shell](https://img.shields.io/badge/shell-blue?logo=gnu-bash)]()
[![Platform](https://img.shields.io/badge/platform-Linux-blue)]()

# Deb SleepWithMe

Schedule automatic server shutdowns by day of week and time.

## Quick Start

```bash
su -
bash <(curl -fsSL https://raw.githubusercontent.com/sosaramosalexis/deb-sleepwithme/main/install.sh)
```

## What it does

Sets up a systemd timer that shuts down your server at a configured time on selected days. Useful for saving power on servers that don't need to run 24/7.

## Options

- **Configure schedule** — pick days (Mon-Sun) and time (HH:MM 24h)
- **View schedule** — shows current config and timer status
- **Remove schedule** — disables timer and cleans up
