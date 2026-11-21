# UK PC Deal & Misprice Tracker

A zero-dependency PowerShell tracker that polls UK PC component deal feeds and sends instant **ntfy.sh** iPhone/Android push notifications and/or **Discord** alerts for:

- **NVMe M.2 SSDs** (2TB+ target £/TB & 30-day lows; 1TB only on extreme bargains/misprices)
- **Graphics Cards (GPUs)**
- **CPUs / Processors**
- **DDR5 RAM** (£/GB thresholds + 30-day lows)
- **Motherboards**

## Sources Polled (No API Keys Needed)
- **HotUKDeals** UK RSS feeds (`ssd`, `storage`, `graphics-card`, `cpu`, `ram`, `motherboard`, `computing`, `new`) — covers Amazon UK, Scan, Overclockers UK, Currys, Ebuyer, CCL, AWD-IT, Box, Very, Argos, etc.
- **CamelCamelCamel UK** Top Relative Price Drops RSS feeds — catches massive Amazon UK % drops and pricing errors.

---

## Option A — Run 24/7 for Free via GitHub Actions (PC Can Be Off)

1. **Publish this folder to GitHub** (using GitHub Desktop or github.com):
   - Use a **Public** repo for **unlimited free 10-minute checks** (your alert topic is never in the code — it stays private in GitHub Secrets).
   - *(If you prefer a **Private** repo, edit `.github/workflows/check-deals.yml` and change `*/10` to `*/30` so it stays well within GitHub's 2,000 free minutes/month.)*
2. **Add your secret on GitHub.com:**
   - Open your repo → **Settings → Secrets and variables → Actions → New repository secret**
   - Name: `NTFY_TOPIC`
   - Secret: your ntfy topic name (e.g. `louie-deals-83921`)
   - *(Optional: also add `DISCORD_WEBHOOK_URL` if you want Discord alerts too.)*
3. **Verify & Seed:**
   - Go to the **Actions** tab → **UK PC Deal & Misprice Tracker** → **Run workflow**:
     - Run once with `test_alert` checked to confirm your iPhone buzzes from the cloud.
     - Run once with defaults to seed your cloud 30-day history (stored cleanly on the `tracker-state` branch).
4. **Pause the local PC task** (so you don't get double notifications while your PC is on):
   ```powershell
   Disable-ScheduledTask -TaskName "UK-PC-Deal-Tracker"
   ```

---

## Option B — Run Locally on Windows (Every 5 Minutes While PC Is On)

Put your local `ntfy_topic` / `discord_webhook_url` in `config.local.json` (gitignored so it never leaks to GitHub), then run:

```powershell
# Verify notifications
powershell -ExecutionPolicy Bypass -File .\check-deals.ps1 -TestAlert

# Preview all currently matched UK PC deals without sending alerts
powershell -ExecutionPolicy Bypass -File .\check-deals.ps1 -DryRun -ShowSummary

# Seed initial 30-day history
powershell -ExecutionPolicy Bypass -File .\check-deals.ps1 -SeedBaseline

# Install / remove 5-minute silent Windows scheduled task
powershell -ExecutionPolicy Bypass -File .\install-task.ps1
powershell -ExecutionPolicy Bypass -File .\uninstall-task.ps1
```

## Customising Thresholds
Edit `config.json` (either locally or directly on GitHub.com) to adjust:
- `categories.nvme_ssd.sale_gbp_per_tb_2tb_plus` / `misprice_gbp_per_tb_2tb_plus` / `misprice_gbp_per_tb_1tb`
- `categories.ddr5_ram.sale_gbp_per_gb` / `misprice_gbp_per_gb`
- `categories.gpu.watched_models`, `categories.cpu.watched_models`, `categories.motherboard.watched_models`
- `alerts.min_alert_tier`: `"MISPRICE"` for extreme deals/pricing errors only, or `"SALE"` for both misprices and 30-day lows/great sales.
