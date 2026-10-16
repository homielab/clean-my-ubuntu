# Privacy policy

*Clean My Ubuntu, by HomieLab — effective 13 October 2026*

Clean My Ubuntu runs entirely on your computer. **It collects no personal data, has no
accounts, no analytics, no ads and no tracking.**

## What stays on your computer

- **What it finds and cleans** — scan results, sizes and file lists are shown to you and never
  sent anywhere.
- **Your choices and settings** — `~/.config/clean-my-ubuntu/`.
- **An activity log** of what was cleaned and when, the last scan results and a daily free-space
  reading — `~/.local/state/clean-my-ubuntu/`. You can view the log in *Settings → Activity log*
  and delete these folders at any time (`cmu --uninstall` offers to).

## When it uses the network

Only to get Clean My Ubuntu itself, from GitHub:

| When | Request | Can I turn it off? |
|---|---|---|
| Once a day while you use the app | Reads the latest version number from `raw.githubusercontent.com` | Yes — *Settings → Daily update check*, or `CMU_NO_UPDATE_CHECK=1`. Never happens when installed as a package. |
| `cmu --update` or *Check for updates now* | Downloads the new version from GitHub | Only when you ask |
| `--install` (script installed on its own) | Downloads the desktop app and icon from GitHub | Only when you ask |

These requests contain nothing about you or your files. Like any web request, GitHub sees your
IP address — see [GitHub's privacy statement](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement).
Cleaning tasks you start may also use your system's own tools that go online (for example
*Maintenance → Update everything* runs `apt update`).

## Contact

Questions about privacy: contact@homielab.com · [homielab.com](https://homielab.com)
