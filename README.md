# OpenWrt Argon Theme Installer

One command installs the latest **LuCI Argon** theme on your router. No hardcoded version — the script always pulls the latest release from [jerrykuku/luci-theme-argon](https://github.com/jerrykuku/luci-theme-argon) via the GitHub API.

## Install

```sh
sh -c "$(wget -O- https://raw.githubusercontent.com/opnwpd/argon-theme-installer/main/install.sh)"
```

No `wget`? Use `curl`:

```sh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/opnwpd/argon-theme-installer/main/install.sh)"
```

## Uninstall

```sh
sh -c "$(wget -O- https://raw.githubusercontent.com/opnwpd/argon-theme-installer/main/uninstall.sh)"
```

## Options

Dry run — check what would happen, no changes made:
```sh
sh -c "$(wget -O- https://raw.githubusercontent.com/opnwpd/argon-theme-installer/main/install.sh)" -- --dry-run
```

Install theme only, skip the config app:
```sh
sh -c "$(wget -O- https://raw.githubusercontent.com/opnwpd/argon-theme-installer/main/install.sh)" -- --theme-only
```

Pin a specific version instead of latest:
```sh
sh -c "$(wget -O- https://raw.githubusercontent.com/opnwpd/argon-theme-installer/main/install.sh)" -- --tag v2.4.6
```

Skip `opkg update`/`apk update` before installing:
```sh
sh -c "$(wget -O- https://raw.githubusercontent.com/opnwpd/argon-theme-installer/main/install.sh)" -- --skip-update
```

## Credits

- Theme: [jerrykuku/luci-theme-argon](https://github.com/jerrykuku/luci-theme-argon)
- Installer concept based on [dagmagnat/argon-theme-installer](https://github.com/dagmagnat/argon-theme-installer)
