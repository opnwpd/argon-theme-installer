#!/bin/sh
# OpenWrt Argon universal installer (upstream-tracking version)
# Supports OPKG based OpenWrt/ImmortalWrt/X-Wrt and APK based OpenWrt snapshots/25.x+.
# Always installs the LATEST release from the official upstream repo:
#   https://github.com/jerrykuku/luci-theme-argon
set -eu

UPSTREAM_OWNER="${UPSTREAM_OWNER:-jerrykuku}"
UPSTREAM_REPO="${UPSTREAM_REPO:-luci-theme-argon}"
UPSTREAM_REF="${UPSTREAM_REF:-latest}"   # "latest" or a tag like "v2.4.6"

API_BASE="https://api.github.com/repos/${UPSTREAM_OWNER}/${UPSTREAM_REPO}"
DL_BASE="https://github.com/${UPSTREAM_OWNER}/${UPSTREAM_REPO}/releases/download"

TMP_DIR="${TMPDIR:-/tmp}/argon-installer.$$"

INSTALL_CONFIG=1
DRY_RUN=0
FORCE_ONLINE=0
UPDATE_LISTS=1

log()  { printf '%s\n' "[argon] $*"; }
warn() { printf '%s\n' "[argon][warn] $*" >&2; }
fail() { printf '%s\n' "[argon][error] $*" >&2; exit 1; }

usage() {
cat <<EOF
OpenWrt Argon universal installer (tracks latest upstream release)

Usage:
  sh install.sh [options]

Options:
  --theme-only     install only luci-theme-argon, skip luci-app-argon-config
  --force-online    allow extra online dependency recovery if install fails
  --skip-update     do not run opkg update/apk update before installation
  --dry-run         print detected system and resolved packages without installing
  --tag TAG         install a specific upstream tag instead of the latest release (e.g. v2.4.6)
  -h, --help        show this help

Environment:
  UPSTREAM_OWNER   GitHub owner of the theme repo, default: ${UPSTREAM_OWNER}
  UPSTREAM_REPO    GitHub repo name, default: ${UPSTREAM_REPO}
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --theme-only) INSTALL_CONFIG=0 ;;
    --force-online) FORCE_ONLINE=1 ;;
    --skip-update) UPDATE_LISTS=0 ;;
    --dry-run) DRY_RUN=1 ;;
    --tag) shift; [ "$#" -gt 0 ] || fail "--tag requires a value"; UPSTREAM_REF="$1" ;;
    --tag=*) UPSTREAM_REF="${1#*=}" ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
  shift
done

cleanup() { rm -rf "$TMP_DIR" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

have() { command -v "$1" >/dev/null 2>&1; }

read_openwrt_info() {
  DISTRIB_ID="unknown"
  DISTRIB_RELEASE="unknown"
  DISTRIB_TARGET="unknown"
  DISTRIB_ARCH="unknown"
  [ -r /etc/openwrt_release ] && . /etc/openwrt_release || true
  if [ "$DISTRIB_ID" = "unknown" ] && [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release || true
    DISTRIB_ID="${NAME:-unknown}"
    DISTRIB_RELEASE="${VERSION_ID:-unknown}"
  fi
}

detect_pkg_manager() {
  if have apk; then
    echo "apk"
  elif have opkg; then
    echo "opkg"
  else
    echo "unknown"
  fi
}

refresh_package_lists() {
  [ "$UPDATE_LISTS" = "1" ] || { log "Package list update skipped by --skip-update"; return 0; }
  if [ "$DRY_RUN" = "1" ]; then
    case "$PKG_MANAGER" in
      opkg) log "DRY-RUN: opkg update" ;;
      apk)  log "DRY-RUN: apk update" ;;
    esac
    return 0
  fi
  case "$PKG_MANAGER" in
    opkg)
      log "Updating OPKG package lists: opkg update"
      opkg update || fail "opkg update failed. Check internet access and configured OpenWrt feeds."
      ;;
    apk)
      log "Updating APK package indexes: apk update"
      apk update || fail "apk update failed. Check internet access and configured OpenWrt repositories."
      ;;
  esac
}

fetch_url_to_stdout() {
  url="$1"
  if have uclient-fetch; then
    uclient-fetch -q -O- "$url" 2>/dev/null || uclient-fetch -q --no-check-certificate -O- "$url"
  elif have wget; then
    wget -q -O- "$url" 2>/dev/null || wget -q --no-check-certificate -O- "$url"
  elif have curl; then
    curl -sL --fail "$url" || curl -sk -L --fail "$url"
  else
    fail "wget/curl/uclient-fetch not found"
  fi
}

fetch_file() {
  url="$1"
  out="$2"
  log "Downloading: $url"
  if have uclient-fetch; then
    uclient-fetch -O "$out" "$url" 2>/dev/null || \
      uclient-fetch --no-check-certificate -O "$out" "$url"
  elif have wget; then
    wget -O "$out" "$url" 2>/dev/null || \
      wget --no-check-certificate -O "$out" "$url"
  elif have curl; then
    curl -L --fail -o "$out" "$url" || \
      curl -k -L --fail -o "$out" "$url"
  else
    fail "wget/curl/uclient-fetch not found"
  fi
}

# Pull release metadata (JSON) from GitHub API and extract asset filenames + tag.
# No jq dependency: plain grep/sed, since most OpenWrt images don't ship jq.
resolve_release() {
  if [ "$UPSTREAM_REF" = "latest" ]; then
    api_url="${API_BASE}/releases/latest"
  else
    api_url="${API_BASE}/releases/tags/${UPSTREAM_REF}"
  fi

  log "Querying upstream release metadata: $api_url"
  release_json="$(fetch_url_to_stdout "$api_url")" || fail "Failed to query GitHub API for upstream release"
  [ -n "$release_json" ] || fail "Empty response from GitHub API (rate limited? no internet?)"

  RESOLVED_TAG="$(printf '%s\n' "$release_json" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/')"
  [ -n "$RESOLVED_TAG" ] || fail "Could not determine upstream release tag (GitHub API response unexpected)"

  # All asset download URLs, one per line
  ASSET_URLS="$(printf '%s\n' "$release_json" | grep -o '"browser_download_url":[[:space:]]*"[^"]*"' | sed -E 's/.*"([^"]+)"$/\1/')"
  [ -n "$ASSET_URLS" ] || fail "No release assets found for tag $RESOLVED_TAG"
}

# Pick the first asset URL whose filename matches a given shell glob-ish regex.
pick_asset() {
  pattern="$1"
  printf '%s\n' "$ASSET_URLS" | grep -E "$pattern" | head -n1
}

backup_luci_theme_setting() {
  mkdir -p /etc/argon-installer 2>/dev/null || true
  if have uci && [ ! -f /etc/argon-installer/previous-mediaurlbase ]; then
    uci get luci.main.mediaurlbase >/etc/argon-installer/previous-mediaurlbase 2>/dev/null || true
  fi
}

activate_argon() {
  if have uci; then
    backup_luci_theme_setting
    uci set luci.main.mediaurlbase='/luci-static/argon' || true
    uci commit luci || true
  fi
  rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
  rm -rf /tmp/luci-modulecache /tmp/luci-modulecache/ 2>/dev/null || true
  /etc/init.d/rpcd restart 2>/dev/null || killall -HUP rpcd 2>/dev/null || true
  /etc/init.d/uhttpd restart 2>/dev/null || true
}

install_with_opkg() {
  theme_url="$(pick_asset '/luci-theme-argon_[^/]*_all\.ipk$')"
  [ -n "$theme_url" ] || fail "No .ipk asset for luci-theme-argon found in release ${RESOLVED_TAG}"

  mkdir -p "$TMP_DIR"
  theme="$TMP_DIR/$(basename "$theme_url")"
  fetch_file "$theme_url" "$theme"
  pkgs="$theme"

  if [ "$INSTALL_CONFIG" = "1" ]; then
    config_url="$(pick_asset '/luci-app-argon-config_[^/]*_all\.ipk$')"
    if [ -n "$config_url" ]; then
      config="$TMP_DIR/$(basename "$config_url")"
      fetch_file "$config_url" "$config"
      pkgs="$pkgs $config"
    else
      warn "No .ipk asset for luci-app-argon-config found in release ${RESOLVED_TAG}; installing theme only"
    fi
  fi

  if [ "$DRY_RUN" = "1" ]; then
    log "DRY-RUN: opkg install $pkgs"
    return 0
  fi

  log "Installing Argon ${RESOLVED_TAG} with opkg"
  if opkg install $pkgs; then
    return 0
  fi

  if [ "$FORCE_ONLINE" = "1" ]; then
    warn "Local opkg install failed. Trying official repositories for missing dependencies."
    opkg update || true
    opkg install curl jsonfilter luci-lua-runtime luci-compat || true
    opkg install $pkgs
  else
    fail "opkg install failed. Run again with --force-online if dependencies are missing."
  fi
}

apk_add_local() {
  # Use configured APK repositories for dependencies, but do not change repository files.
  apk add --allow-untrusted "$@"
}

install_with_apk() {
  theme_url="$(pick_asset '/luci-theme-argon-[0-9][^/]*\.apk$')"
  [ -n "$theme_url" ] || fail "No .apk asset for luci-theme-argon found in release ${RESOLVED_TAG}"

  mkdir -p "$TMP_DIR"
  theme="$TMP_DIR/$(basename "$theme_url")"
  fetch_file "$theme_url" "$theme"
  set -- "$theme"

  if [ "$INSTALL_CONFIG" = "1" ]; then
    config_url="$(pick_asset '/luci-app-argon-config-[0-9][^/]*\.apk$')"
    if [ -n "$config_url" ]; then
      config="$TMP_DIR/$(basename "$config_url")"
      fetch_file "$config_url" "$config"
      set -- "$theme" "$config"
    else
      warn "No .apk asset for luci-app-argon-config found in release ${RESOLVED_TAG} (upstream often only ships it as .ipk); installing theme only"
    fi
  fi

  if [ "$DRY_RUN" = "1" ]; then
    log "DRY-RUN: apk add --allow-untrusted $*"
    return 0
  fi

  log "Installing Argon ${RESOLVED_TAG} with apk"
  apk_add_local "$@"
}

read_openwrt_info
PKG_MANAGER="$(detect_pkg_manager)"

log "Firmware: ${DISTRIB_ID} ${DISTRIB_RELEASE}"
log "Target: ${DISTRIB_TARGET}; arch: ${DISTRIB_ARCH}"
log "Package manager: ${PKG_MANAGER}"
log "Upstream: ${UPSTREAM_OWNER}/${UPSTREAM_REPO} (ref: ${UPSTREAM_REF})"

case "$PKG_MANAGER" in
  apk|opkg) refresh_package_lists ;;
  *) fail "Neither apk nor opkg was found. This does not look like a supported OpenWrt-like system." ;;
esac

resolve_release
log "Resolved upstream release: ${RESOLVED_TAG}"

case "$PKG_MANAGER" in
  apk)  install_with_apk ;;
  opkg) install_with_opkg ;;
  *) fail "Neither apk nor opkg was found. This does not look like a supported OpenWrt-like system." ;;
esac

if [ "$DRY_RUN" = "0" ]; then
  activate_argon
  log "Done. Argon ${RESOLVED_TAG} is installed and selected as LuCI theme. Reopen LuCI or refresh the page."
else
  log "Dry run finished. No changes were made."
fi
