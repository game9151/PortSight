# Changelog

## 1.0.0

- One-click fix: when closing the lid switches your monitor to a mode that doesn't work, a button pins the lid-closed mode to the one that does and turns lid profiles on.
- Refresh rate switcher in the menu bar, using the same 15-second Keep or go back safety.
- Link details are matched to the right monitor when you have more than one.
- Update check against GitHub releases (once a day, can be turned off). It only downloads the public release list.
- Notification status on the Alerts page, with a test button or a shortcut to Notification settings if macOS blocks them.
- Report now includes the colour format and the best-setup table.
- Colour format and DDC recover after a monitor is replugged.
- `--self-test` and `--version` on the command line; CI runs the self-test on every push.

## 0.2.0

- Live alerts for slower links, 4:2:2 fallback, a nearly full cable, lid-close refresh changes, power drops and lost monitor links.
- Best-setup advisor per monitor.
- Colour format view and switching (experimental, Apple silicon).
- DDC brightness, contrast and volume (Apple silicon).
- Link history cache: repeat reports in about 2 seconds instead of about 27.
- App icon, notarisation-ready build script, GitHub Actions build.

## 0.1.0

- First release: findings, displays and modes with bandwidth estimates, connections, lid profiles, report, command line.
