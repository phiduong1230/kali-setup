# Kali Linux Setup Scripts

Post-install automation for Kali Linux that handles system setup, tool installation, and optional debloating.

Two complementary scripts for getting a fresh Kali Linux install into a comfortable, usable state:
- **setup.sh** - Updates system, installs baseline tools, configures firewall, optionally installs popular apps
- **debloat.sh** - Removes unnecessary packages to free disk space and reduce clutter

Both scripts follow a "keep going" approach - they continue even if a step fails, then show you what went wrong at the end.

## Quick Start

Run setup.sh first to set up your system:
```bash
chmod +x setup.sh
sudo ./setup.sh --brave --vscodium
```

Then optionally run debloat.sh to remove bloat:
```bash
chmod +x debloat.sh
sudo ./debloat.sh --kernels
```

## How These Scripts Work

### Continue-on-error behavior
Both scripts are designed to continue execution even if a step fails. At the end, you'll see a clear summary of what failed. This prevents losing progress just because one repo was unreachable.

### Logging behavior
- All output is captured while scripts run
- Log files are only saved if something fails or if you use `--log`
- On successful runs without `--log`, the temporary logs are automatically discarded

This keeps your directory clean while making troubleshooting easy when needed.

### APT lock handling
Before running apt commands, scripts wait for package manager locks to clear so they don't fail if another process is using APT.

---

## Setup Script

Sets up a fresh Kali install with updates, baseline tools, firewall configuration, and optional applications.

### What it does

**1) Updates your system**
- Runs `apt-get update` and `apt-get upgrade -y`

**2) Installs baseline packages**

Installs practical tools most people want:
- Basics: `curl`, `wget`, `git`, `ca-certificates`, `gnupg`
- Admin tools: `btop`, `net-tools`, `ufw`
- Archive tools: `zip`, `unzip`, `p7zip-full`
- Editor + restore tool: `vim`, `timeshift`
- Media player: `vlc`

**3) Enables firewall (UFW)**
- Default deny incoming
- Default allow outgoing
- Enable firewall

Suitable for most personal Kali systems. Add rules afterward if you need inbound access for services.

**4) Optional applications**

Nothing extra is installed unless you explicitly request using flags.

**5) Cleanup**
- Removes unused packages
- Cleans APT cache
- Runs `systemd-tmpfiles --clean`
- Removes thumbnail cache

### Usage

```bash
chmod +x setup.sh
sudo ./setup.sh
```

View help:
```bash
sudo ./setup.sh --help
```

### Flags

| Flag           | What it does                                                |
| -------------- | ----------------------------------------------------------- |
| `--log`        | Always keep setup.log (even if everything succeeds)     |
| `--pwfeedback` | Enables sudo password feedback                              |
| `--brave`      | Adds Brave's repo + installs brave-browser                  |
| `--mullvad`    | Adds Mullvad's repo + installs Mullvad VPN and browser      |
| `--rustdesk`   | Installs RustDesk remote desktop client from latest release |
| `--vscodium`   | Adds VSCodium repo + installs codium                        |
| `--docker`     | Installs Docker Engine using Docker's Debian repo for Kali  |

### Examples

Baseline only:
```bash
sudo ./setup.sh
```

Install common apps:
```bash
sudo ./setup.sh --brave --vscodium --docker
```

Enable sudo password feedback:
```bash
sudo ./setup.sh --pwfeedback
```

Always save a log:
```bash
sudo ./setup.sh --log
```

### Docker installation notes

Kali reports its codename as `kali-rolling`, which doesn't work with Docker's Debian repos. This script:
- Infers the Debian base (`trixie` or `bookworm`) using the installed `libc6` version
- Removes stale Docker repo entries if present
- Installs Docker from Docker's official Debian repository
- Adds the user to the `docker` group

After installation, log out and back in (or reboot) before using Docker without `sudo`.

### RustDesk installation notes

When `--rustdesk` is used:
- Detects system architecture (`amd64` or `arm64`)
- Queries RustDesk's latest GitHub release
- Downloads and installs the matching `.deb` package
- Cleans up temporary files

RustDesk is installed without adding a persistent APT repository.

### What changes on disk

Depending on flags used, may create or modify:
- UFW firewall state and defaults
- `/etc/sudoers.d/setup-pwfeedback` (only with `--pwfeedback`)
- APT source files for Brave, Mullvad, VSCodium, Docker (with their respective flags)
- Temporary files under `/tmp` during installs
- `setup.log` (only on failure or with `--log`)

---

## Debloat Script

Removes unnecessary packages from Kali Linux to free disk space and reduce clutter.

### What it does

**1) Shows what will be removed and asks for confirmation**

Before doing anything, displays a list of packages that will be removed and waits for your confirmation. Nothing happens until you enter `y`.

**2) Removes default bloat packages**

Removes packages most Kali users don't need:

| Package | What it is |
|---------|------------|
| totem | GNOME Videos player |
| orca | Screen reader |
| rygel | DLNA/UPnP media streaming server |
| bolt | Thunderbolt device manager |
| gnome-user-docs | GNOME help documentation |
| yelp | Help viewer app |
| malcontent | Parental controls |
| gnome-remote-desktop | GNOME's remote desktop server |
| packagekit | Software center backend |

These have minimal dependencies and won't break your desktop environment.

**3) Optional: removes old Linux kernels**

With `--kernels`, detects and removes old kernel packages while keeping:
- Currently running kernel
- Meta-package (`linux-image-amd64`)

Can free significant disk space on older installations.

**4) Optional: removes Firefox**

With `--firefox`, removes Firefox ESR using a stub package approach.

Kali's `kali-desktop-core` depends on `firefox-esr | firefox`. You can't just purge it without breaking some dependencies. The script:
- Creates a stub package (`debloat-firefox-stub`) that satisfies the dependency
- Installs the stub
- Purges `firefox-esr`
- Removes leftover `~/.mozilla` files
- Sets Brave as default browser if installed

The stub package is tiny (~1KB) and just tells APT "the Firefox dependency is satisfied."

**5) Cleanup**
- Removes unused dependencies
- Cleans APT cache

### Usage

```bash
chmod +x debloat.sh
sudo ./debloat.sh
```

View help:
```bash
sudo ./debloat.sh --help
```

### Flags

| Flag        | What it does                                                     |
|-------------|------------------------------------------------------------------|
| `--log`     | Always keep debloat.log (even if everything succeeds)            |
| `--kernels` | Also remove old Linux kernels (keeps currently running kernel)   |
| `--firefox` | Remove Firefox ESR and replace with stub package                 |

### Examples

Remove default bloat only:
```bash
sudo ./debloat.sh
```

Also remove old kernels:
```bash
sudo ./debloat.sh --kernels
```

Also remove Firefox:
```bash
sudo ./debloat.sh --firefox
```

Remove everything and keep a log:
```bash
sudo ./debloat.sh --kernels --firefox --log
```

### How to undo

Reinstall removed packages:
```bash
sudo apt install totem orca rygel bolt gnome-user-docs yelp malcontent gnome-remote-desktop packagekit
```

Reinstall Firefox after using `--firefox`:
```bash
sudo apt purge debloat-firefox-stub
sudo apt install firefox-esr
```

Note: Old kernels cannot be easily restored. If you need a previous kernel, install it manually from Kali repositories.

### What changes on disk

Depending on flags used, may create or modify:
- Removed packages and their config files (purged)
- `debloat-firefox-stub` package installed (only with `--firefox`)
- `~/.mozilla` directory removed (only with `--firefox`)
- Default browser setting (only with `--firefox` if Brave is installed)
- `debloat.log` (only on failure or with `--log`)

---

## Troubleshooting

### "Command not found" when running scripts

Common causes:
- Not in the same directory as the script
- Script isn't executable
- Filename doesn't match what you typed

Fix:
```bash
cd /path/to/the/script
chmod +x setup.sh
sudo ./setup.sh
```

### Check the logs

If a script reports errors or you used `--log`:
```bash
less ./setup.log
```

### Firefox removal failed (debloat.sh)

Check if:
- `equivs` failed to install (possible network issue)
- Stub package failed to build (check logs)
- `firefox-esr` was already removed some other way

### "Nothing to remove" message (debloat.sh)

None of the target packages are currently installed. System is already debloated.

### Docker doesn't work without sudo (setup.sh)

After Docker installation, you may need to log out and back in (or reboot) for the group membership to take effect.

---

## When You Might Not Want These Scripts

**Setup:**
- You need custom firewall rules for inbound services
- You prefer a very minimal Kali install
- You already manage packages and repositories manually

**Debloat:**
- You use GNOME Videos (totem) or other removed apps
- You rely on accessibility features (orca screen reader)
- You use Thunderbolt devices (bolt)
- You want to keep Firefox as your browser
- You want old kernels as fallback options
