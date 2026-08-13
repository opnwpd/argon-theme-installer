#!/bin/sh
# OpenWrt Argon universal uninstaller
# Removes luci-theme-argon and luci-app-argon-config, restores the previous LuCI theme.
set -eu

BACKUP_FILE="/etc/argon-installer/previous-mediaurlbase"

log()  { printf '%s\n' "[argon] $*"; }
warn() { printf '%s\n' "[argon][warn] $*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

detect_pkg_manager() {
  if have apk; then
    echo "apk"
  elif have opkg; then
    echo "opkg"
  else
    echo "unknown"
  fi
}

PKG_MANAGER="$(detect_pkg_manager)"
log "Package manager: ${PKG_MANAGER}"

remove_packages() {
  case "$PKG_MANAGER" in
    opkg)
      opkg remove luci-app-argon-config 2>/dev/null || true
      opkg remove luci-theme-argon 2>/dev/null || true
      ;;
    apk)
      apk del luci-app-argon-config 2>/dev/null || true
      apk del luci-theme-argon 2>/dev/null || true
      ;;
    *)
      warn "Neither apk nor opkg found; skipping package removal"
      ;;
  esac
}

restore_previous_theme() {
  if ! have uci; then
    warn "uci not found; cannot restore previous theme setting"
    return 0
  fi

  if [ -f "$BACKUP_FILE" ]; then
    previous="$(cat "$BACKUP_FILE" 2>/dev/null || true)"
    if [ -n "$previous" ]; then
      log "Restoring previous LuCI theme: $previous"
      uci set luci.main.mediaurlbase="$previous" || true
    else
      log "Backup file was empty; falling back to Bootstrap"
      uci set luci.main.mediaurlbase='/luci-static/bootstrap' || true
    fi
    rm -f "$BACKUP_FILE"
  else
    log "No previous theme backup found; falling back to Bootstrap"
    uci set luci.main.mediaurlbase='/luci-static/bootstrap' || true
  fi

  uci commit luci || true
}

clear_luci_cache() {
  rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
  rm -rf /tmp/luci-modulecache /tmp/luci-modulecache/ 2>/dev/null || true
  /etc/init.d/rpcd restart 2>/dev/null || killall -HUP rpcd 2>/dev/null || true
  /etc/init.d/uhttpd restart 2>/dev/null || true
}

remove_packages
restore_previous_theme
clear_luci_cache

log "Done. Argon theme removed, previous LuCI theme restored. Reopen LuCI or refresh the page."
