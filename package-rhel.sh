#!/usr/bin/env bash
set -euo pipefail

MIN_KERNEL="6.11"
DEFAULT_CORE_MODE="both"
DEFAULT_CHANNEL="latest"
PROJECT_HINT="v2rayN.Desktop/v2rayN.Desktop.csproj"
BUILD_CONFIG="Release"
TARGET_FRAMEWORK="net8.0"
PKGROOT="v2rayN-publish"

VERSION_ARG=""
WITH_CORE="$DEFAULT_CORE_MODE"
FORCE_NETCORE=0
ARCH_OVERRIDE=""
BUILD_FROM=""
XRAY_VER="${XRAY_VER:-}"
SING_VER="${SING_VER:-}"

OS_ID=""
OS_NAME=""
OS_VERSION=""
HOST_ARCH=""
SCRIPT_DIR=""
PROJECT=""
VERSION=""
BUILT_ALL=0

declare -a TARGETS=()
declare -a BUILT_RPMS=()

die() {
  echo "$*" >&2
  exit 1
}

parse_args() {
  local arg
  VERSION_ARG=""

  while (($#)); do
    arg="$1"
    case "$arg" in
      --with-core)   WITH_CORE="${2:-both}"; shift 2 ;;
      --xray-ver)    XRAY_VER="${2:-}"; shift 2 ;;
      --singbox-ver) SING_VER="${2:-}"; shift 2 ;;
      --netcore)     FORCE_NETCORE=1; shift ;;
      --arch)        ARCH_OVERRIDE="${2:-}"; shift 2 ;;
      --buildfrom)   BUILD_FROM="${2:-}"; shift 2 ;;
      --*)
        die "Unknown option: $arg"
        ;;
      *)
        if [[ -z "$VERSION_ARG" ]]; then
          VERSION_ARG="$arg"
        else
          die "Unexpected argument: $arg"
        fi
        shift
        ;;
    esac
  done

  [[ -n "$VERSION_ARG" && -n "$BUILD_FROM" ]] && die "You cannot specify both an explicit version and --buildfrom at the same time.
        Provide either a version (e.g. 7.14.0) OR --buildfrom 1|2|3."
}

detect_environment() {
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_NAME="${NAME:-$OS_ID}"
  OS_VERSION="${VERSION_ID:-}"
  HOST_ARCH="$(uname -m)"

  case "$OS_ID" in
    rhel|rocky|almalinux|fedora|centos)
      echo "Detected supported system: ${OS_NAME} ${OS_VERSION}"
      ;;
    *)
      die "Unsupported system: ${OS_NAME:-unknown} (${OS_ID:-unknown}).
This script only supports: RHEL / Rocky / AlmaLinux / Fedora / CentOS."
      ;;
  esac

  case "$HOST_ARCH" in
    aarch64|x86_64) ;;
    *) die "Only supports aarch64 / x86_64" ;;
  esac
}

verify_kernel() {
  local current lowest
  current="$(uname -r)"
  lowest="$(printf '%s\n%s\n' "$MIN_KERNEL" "$current" | sort -V | head -n1)"
  [[ "$lowest" == "$MIN_KERNEL" ]] || die "Kernel $current is below $MIN_KERNEL"
  echo "[OK] Kernel $current verified."
}

install_dependencies() {
  local ok=0

  if command -v dnf >/dev/null 2>&1; then
    sudo dnf -y install rpm-build rpmdevtools curl unzip tar jq rsync dotnet-sdk-8.0 && ok=1
  fi

  (( ok == 1 )) || echo "Could not auto-install dependencies for '$OS_ID'. Make sure these are available:
dotnet-sdk 8.x, curl, unzip, tar, rsync, rpm, rpmdevtools, rpm-build (on Red Hat branch)"
}

enter_workspace() {
  SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  cd "$SCRIPT_DIR"
}

sync_submodules() {
  [[ -f .gitmodules ]] || return 0
  git submodule sync --recursive || true
  git submodule update --init --recursive || true
}

locate_project() {
  PROJECT="$PROJECT_HINT"
  [[ -f "$PROJECT" ]] || PROJECT="$(find . -maxdepth 3 -name 'v2rayN.Desktop.csproj' | head -n1 || true)"
  [[ -f "$PROJECT" ]] || die "v2rayN.Desktop.csproj not found"
}

choose_channel() {
  local choice="${DEFAULT_CHANNEL}" input=""

  case "${BUILD_FROM:-}" in
    1) printf '%s\n' "latest"; return 0 ;;
    2) printf '%s\n' "prerelease"; return 0 ;;
    3) printf '%s\n' "keep"; return 0 ;;
    "") ;;
    *) die "[ERROR] Invalid --buildfrom value: ${BUILD_FROM}. Use 1|2|3." ;;
  esac

  if [[ -t 0 ]]; then
    {
      echo "[?] Choose v2rayN release channel:"
      echo "    1) Latest (stable)  [default]"
      echo "    2) Pre-release (preview)"
      echo "    3) Keep current (do nothing)"
      printf 'Enter 1, 2 or 3 [default 1]: '
    } >&2

    if read -r input </dev/tty; then
      case "${input:-}" in
        2) choice="prerelease" ;;
        3) choice="keep" ;;
      esac
    fi
  fi

  printf '%s\n' "$choice"
}

get_latest_tag_latest() {
  curl -fsSL "https://api.github.com/repos/2dust/v2rayN/releases/latest" \
    | jq -re '.tag_name' \
    | sed 's/^v//'
}

get_latest_tag_prerelease() {
  curl -fsSL "https://api.github.com/repos/2dust/v2rayN/releases?per_page=20" \
    | jq -re 'first(.[] | select(.prerelease == true) | .tag_name)' \
    | sed 's/^v//'
}

git_try_checkout() {
  local want="$1"

  git rev-parse --git-dir >/dev/null 2>&1 || return 1
  git fetch --tags --force --prune --depth=1 || true
  git rev-parse "refs/tags/${want}" >/dev/null 2>&1 || return 1

  echo "[OK] Found ref '${want}', checking out..."
  git checkout -f "$want"
  sync_submodules
}

apply_channel_or_keep() {
  local channel="$1" tag=""

  case "$channel" in
    keep)
      echo "[*] Keep current repository state (no checkout)."
      VERSION="$(git describe --tags --abbrev=0 2>/dev/null || echo '0.0.0+git')"
      VERSION="${VERSION#v}"
      ;;
    latest)
      echo "[*] Resolving ${channel} tag from GitHub releases..."
      tag="$(get_latest_tag_latest || true)"
      [[ -n "$tag" ]] || die "Failed to resolve latest tag for channel '${channel}'."
      echo "[*] Latest tag for '${channel}': ${tag}"
      git_try_checkout "$tag" || die "Failed to checkout '${tag}'."
      VERSION="${tag#v}"
      ;;
    prerelease)
      echo "[*] Resolving ${channel} tag from GitHub releases..."
      tag="$(get_latest_tag_prerelease || true)"
      [[ -n "$tag" ]] || die "Failed to resolve latest tag for channel '${channel}'."
      echo "[*] Latest tag for '${channel}': ${tag}"
      git_try_checkout "$tag" || die "Failed to checkout '${tag}'."
      VERSION="${tag#v}"
      ;;
    *)
      die "Unknown channel: $channel"
      ;;
  esac
}

resolve_version() {
  local channel clean_ver

  if git rev-parse --git-dir >/dev/null 2>&1; then
    if [[ -n "$VERSION_ARG" ]]; then
      clean_ver="${VERSION_ARG#v}"
      if git_try_checkout "$clean_ver"; then
        VERSION="$clean_ver"
      else
        echo "[WARN] Tag '${VERSION_ARG}' not found."
        channel="$(choose_channel)"
        apply_channel_or_keep "$channel"
      fi
    else
      channel="$(choose_channel)"
      apply_channel_or_keep "$channel"
    fi
  else
    echo "Current directory is not a git repo; proceeding on current tree."
    VERSION="${VERSION_ARG:-0.0.0}"
  fi

  VERSION="${VERSION#v}"
  echo "[*] GUI version resolved as: ${VERSION}"
}

describe_target() {
  local short="$1"

  case "$short" in
    x64)
      printf '%s\n' "linux-x64" "x86_64" "x86_64"
      ;;
    arm64)
      printf '%s\n' "linux-arm64" "aarch64" "aarch64"
      ;;
    *)
      return 1
      ;;
  esac
}

select_targets() {
  BUILT_ALL=0
  TARGETS=()

  case "${ARCH_OVERRIDE:-}" in
    all)
      TARGETS=(x64 arm64)
      BUILT_ALL=1
      ;;
    x64|amd64)
      TARGETS=(x64)
      ;;
    arm64|aarch64)
      TARGETS=(arm64)
      ;;
    "")
      case "$HOST_ARCH" in
        x86_64) TARGETS=(x64) ;;
        aarch64) TARGETS=(arm64) ;;
      esac
      ;;
    *)
      die "Unknown --arch '${ARCH_OVERRIDE}'. Use x64|arm64|all."
      ;;
  esac
}

xray_url_for_rid() {
  local rid="$1" ver="$2"

  case "$rid" in
    linux-x64)   printf '%s\n' "https://github.com/XTLS/Xray-core/releases/download/v${ver}/Xray-linux-64.zip" ;;
    linux-arm64) printf '%s\n' "https://github.com/XTLS/Xray-core/releases/download/v${ver}/Xray-linux-arm64-v8a.zip" ;;
    *) return 1 ;;
  esac
}

singbox_url_for_rid() {
  local rid="$1" ver="$2"

  case "$rid" in
    linux-x64)   printf '%s\n' "https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-amd64.tar.gz" ;;
    linux-arm64) printf '%s\n' "https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-arm64.tar.gz" ;;
    *) return 1 ;;
  esac
}

bundle_url_for_rid() {
  local rid="$1"

  case "$rid" in
    linux-x64)   printf '%s\n' "https://raw.githubusercontent.com/2dust/v2rayN-core-bin/refs/heads/master/v2rayN-linux-64.zip" ;;
    linux-arm64) printf '%s\n' "https://raw.githubusercontent.com/2dust/v2rayN-core-bin/refs/heads/master/v2rayN-linux-arm64.zip" ;;
    *) return 1 ;;
  esac
}

download_xray() {
  local outdir="$1" rid="$2" ver="${XRAY_VER:-}" url="" tmp=""
  mkdir -p "$outdir"

  if [[ -z "$ver" ]]; then
    ver="$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest \
      | grep -Eo '"tag_name":\s*"v[^"]+"' \
      | sed -E 's/.*"v([^"]+)".*/\1/' \
      | head -n1)" || true
  fi

  [[ -n "$ver" ]] || { echo "[xray] Failed to get version"; return 1; }
  url="$(xray_url_for_rid "$rid" "$ver")" || { echo "[xray] Unsupported RID: $rid"; return 1; }

  echo "[+] Download xray: $url"
  tmp="$(mktemp -d)"
  curl -fL "$url" -o "$tmp/xray.zip"
  unzip -q "$tmp/xray.zip" -d "$tmp"
  install -m 755 "$tmp/xray" "$outdir/xray"
  rm -rf "$tmp"
}

download_singbox() {
  local outdir="$1" rid="$2" ver="${SING_VER:-}" url="" tmp="" bin="" cronet=""
  mkdir -p "$outdir"

  if [[ -z "$ver" ]]; then
    ver="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest \
      | grep -Eo '"tag_name":\s*"v[^"]+"' \
      | sed -E 's/.*"v([^"]+)".*/\1/' \
      | head -n1)" || true
  fi

  [[ -n "$ver" ]] || { echo "[sing-box] Failed to get version"; return 1; }
  url="$(singbox_url_for_rid "$rid" "$ver")" || { echo "[sing-box] Unsupported RID: $rid"; return 1; }

  echo "[+] Download sing-box: $url"
  tmp="$(mktemp -d)"
  curl -fL "$url" -o "$tmp/singbox.tar.gz"
  tar -C "$tmp" -xzf "$tmp/singbox.tar.gz"
  bin="$(find "$tmp" -type f -name 'sing-box' | head -n1 || true)"
  [[ -n "$bin" ]] || { echo "[!] sing-box unpack failed"; rm -rf "$tmp"; return 1; }
  install -m 755 "$bin" "$outdir/sing-box"
  cronet="$(find "$tmp" -type f -name 'libcronet*.so*' | head -n1 || true)"
  [[ -n "$cronet" ]] && install -m 644 "$cronet" "$outdir/libcronet.so"
  rm -rf "$tmp"
}

unify_geo_layout() {
  local outroot="$1" name
  mkdir -p "$outroot/bin"

  for name in geosite.dat geoip.dat geoip-only-cn-private.dat Country.mmdb geoip.metadb; do
    [[ -f "$outroot/bin/xray/$name" ]] && mv -f "$outroot/bin/xray/$name" "$outroot/bin/$name"
  done
}

download_geo_assets() {
  local outroot="$1" bin_dir="$outroot/bin" srss_dir="$outroot/bin/srss" file
  mkdir -p "$bin_dir" "$srss_dir"

  echo "[+] Download Xray Geo to ${bin_dir}"
  curl -fsSL -o "$bin_dir/geosite.dat" "https://github.com/Loyalsoldier/V2ray-rules-dat/releases/latest/download/geosite.dat"
  curl -fsSL -o "$bin_dir/geoip.dat" "https://github.com/Loyalsoldier/V2ray-rules-dat/releases/latest/download/geoip.dat"
  curl -fsSL -o "$bin_dir/geoip-only-cn-private.dat" "https://raw.githubusercontent.com/Loyalsoldier/geoip/release/geoip-only-cn-private.dat"
  curl -fsSL -o "$bin_dir/Country.mmdb" "https://raw.githubusercontent.com/Loyalsoldier/geoip/release/Country.mmdb"

  echo "[+] Download sing-box rule DB & rule-sets"
  curl -fsSL -o "$bin_dir/geoip.metadb" "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geoip.metadb" || true

  for file in geoip-private.srs geoip-cn.srs geoip-facebook.srs geoip-fastly.srs geoip-google.srs geoip-netflix.srs geoip-telegram.srs geoip-twitter.srs; do
    curl -fsSL -o "$srss_dir/$file" "https://raw.githubusercontent.com/2dust/sing-box-rules/rule-set-geoip/$file" || true
  done

  for file in geosite-cn.srs geosite-gfw.srs geosite-google.srs geosite-greatfire.srs geosite-geolocation-cn.srs geosite-category-ads-all.srs geosite-private.srs; do
    curl -fsSL -o "$srss_dir/$file" "https://raw.githubusercontent.com/2dust/sing-box-rules/rule-set-geosite/$file" || true
  done

  unify_geo_layout "$outroot"
}

prepare_asset_dirs() {
  local outroot="$1"
  mkdir -p "$outroot/bin/xray" "$outroot/bin/sing_box"
}

populate_assets_zip_mode() {
  local outroot="$1" rid="$2" url="" tmp="" nested_dir=""
  prepare_asset_dirs "$outroot"

  url="$(bundle_url_for_rid "$rid")" || { echo "[!] Bundle unsupported RID: $rid"; return 1; }

  echo "[+] Try v2rayN bundle archive: $url"
  tmp="$(mktemp -d)"
  curl -fL "$url" -o "$tmp/v2rayn.zip" || { echo "[!] Bundle download failed"; rm -rf "$tmp"; return 1; }
  unzip -q "$tmp/v2rayn.zip" -d "$tmp" || { echo "[!] Bundle unzip failed"; rm -rf "$tmp"; return 1; }

  if [[ -d "$tmp/bin" ]]; then
    rsync -a "$tmp/bin/" "$outroot/bin/"
  else
    rsync -a "$tmp/" "$outroot/"
  fi

  rm -f "$outroot/v2rayn.zip" 2>/dev/null || true
  find "$outroot" -type d -name "mihomo" -prune -exec rm -rf {} + 2>/dev/null || true

  nested_dir="$(find "$outroot" -maxdepth 1 -type d -name 'v2rayN-linux-*' | head -n1 || true)"
  if [[ -n "$nested_dir" && -d "$nested_dir/bin" ]]; then
    rsync -a "$nested_dir/bin/" "$outroot/bin/"
    rm -rf "$nested_dir"
  fi

  unify_geo_layout "$outroot"
  echo "[+] Bundle extracted to $outroot"
  rm -rf "$tmp"
}

populate_assets_netcore_mode() {
  local outroot="$1" rid="$2"
  prepare_asset_dirs "$outroot"

  case "$WITH_CORE" in
    xray|both)
      download_xray "$outroot/bin/xray" "$rid" || echo "[!] xray download failed (skipped)"
      ;;
  esac

  case "$WITH_CORE" in
    sing-box|both)
      download_singbox "$outroot/bin/sing_box" "$rid" || echo "[!] sing-box download failed (skipped)"
      ;;
  esac

  download_geo_assets "$outroot" || echo "[!] Geo rules download failed (skipped)"
}

stage_runtime_assets() {
  local outroot="$1" rid="$2"

  if (( FORCE_NETCORE == 0 )); then
    if populate_assets_zip_mode "$outroot" "$rid"; then
      echo "[*] Using v2rayN bundle archive."
    else
      echo "[*] Bundle failed, fallback to separate core + rules."
      populate_assets_netcore_mode "$outroot" "$rid"
    fi
  else
    echo "[*] --netcore specified: use separate core + rules."
    populate_assets_netcore_mode "$outroot" "$rid"
  fi
}

build_publish() {
  local rid="$1" pubdir=""

  dotnet clean "$PROJECT" -c "$BUILD_CONFIG"
  rm -rf "$(dirname "$PROJECT")/bin/${BUILD_CONFIG}/${TARGET_FRAMEWORK}" || true
  dotnet restore "$PROJECT"
  dotnet publish "$PROJECT" -c "$BUILD_CONFIG" -r "$rid" -p:PublishSingleFile=false -p:SelfContained=true

  pubdir="$(dirname "$PROJECT")/bin/${BUILD_CONFIG}/${TARGET_FRAMEWORK}/${rid}/publish"
  [[ -d "$pubdir" ]] || die "Publish directory not found: $pubdir"
  printf '%s\n' "$pubdir"
}

package_rpm() {
  local rid="$1" rpm_target="$2" archdir="$3" pubdir="$4"
  local workdir="" topdir="" specdir="" sourcedir="" specfile="" project_dir="" icon_candidate="" f=""
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  rpmdev-setuptree
  topdir="${HOME}/rpmbuild"
  specdir="${topdir}/SPECS"
  sourcedir="${topdir}/SOURCES"

  mkdir -p "$workdir/$PKGROOT"
  cp -a "$pubdir/." "$workdir/$PKGROOT/"

  project_dir="$(cd "$(dirname "$PROJECT")" && pwd)"
  icon_candidate="$project_dir/v2rayN.png"
  [[ -f "$icon_candidate" ]] || die "Required icon not found: $icon_candidate"
  cp "$icon_candidate" "$workdir/$PKGROOT/v2rayn.png"

  stage_runtime_assets "$workdir/$PKGROOT" "$rid"

  mkdir -p "$sourcedir"
  tar -C "$workdir" -czf "$sourcedir/$PKGROOT.tar.gz" "$PKGROOT"

  mkdir -p "$specdir"
  specfile="$specdir/v2rayN.spec"

  cat > "$specfile" <<'SPEC'
%global debug_package %{nil}
%undefine _debuginfo_subpackages
%undefine _debugsource_packages
%global __requires_exclude ^liblttng-ust\.so\..*$

Name:           v2rayN
Version:        __VERSION__
Release:        1%{?dist}
Summary:        v2rayN (Avalonia) GUI client for Linux (x86_64/aarch64)
License:        GPL-3.0-only
URL:            https://github.com/2dust/v2rayN
BugURL:         https://github.com/2dust/v2rayN/issues
ExclusiveArch:  aarch64 x86_64
Source0:        __PKGROOT__.tar.gz

Requires:       cairo, pango, openssl, mesa-libEGL, mesa-libGL
Requires:       glibc >= 2.34
Requires:       fontconfig >= 2.13.1
Requires:       desktop-file-utils >= 0.26
Requires:       xdg-utils >= 1.1.3
Requires:       coreutils >= 8.32
Requires:       bash >= 5.1
Requires:       freetype >= 2.10

%description
v2rayN Linux for Red Hat Enterprise Linux
Support vless / vmess / Trojan / http / socks / Anytls / Hysteria2 / Shadowsocks / tuic / WireGuard
Support Red Hat Enterprise Linux / Fedora Linux / Rocky Linux / AlmaLinux / CentOS
For more information, Please visit our website
https://github.com/2dust/v2rayN

%prep
%setup -q -n __PKGROOT__

%build

%install
install -dm0755 %{buildroot}/opt/v2rayN
cp -a * %{buildroot}/opt/v2rayN/
find %{buildroot}/opt/v2rayN -type d -exec chmod 0755 {} +
find %{buildroot}/opt/v2rayN -type f -exec chmod 0644 {} +
[ -f %{buildroot}/opt/v2rayN/v2rayN ] && chmod 0755 %{buildroot}/opt/v2rayN/v2rayN || :

install -dm0755 %{buildroot}%{_bindir}
install -m0755 /dev/stdin %{buildroot}%{_bindir}/v2rayn << 'EOF'
#!/usr/bin/bash
set -euo pipefail
DIR="/opt/v2rayN"
if [[ -x "$DIR/v2rayN" ]]; then exec "$DIR/v2rayN" "$@"; fi
for dll in v2rayN.Desktop.dll v2rayN.dll; do
  if [[ -f "$DIR/$dll" ]]; then exec /usr/bin/dotnet "$DIR/$dll" "$@"; fi
done
echo "v2rayN launcher: no executable found in $DIR" >&2
ls -l "$DIR" >&2 || true
exit 1
EOF

install -dm0755 %{buildroot}%{_datadir}/applications
install -m0644 /dev/stdin %{buildroot}%{_datadir}/applications/v2rayn.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=v2rayN
Comment=v2rayN for Red Hat Enterprise Linux
Exec=v2rayn
Icon=v2rayn
Terminal=false
Categories=Network;
EOF

install -dm0755 %{buildroot}%{_datadir}/icons/hicolor/256x256/apps
install -m0644 %{_builddir}/__PKGROOT__/v2rayn.png %{buildroot}%{_datadir}/icons/hicolor/256x256/apps/v2rayn.png

%post
/usr/bin/update-desktop-database %{_datadir}/applications >/dev/null 2>&1 || true
/usr/bin/gtk-update-icon-cache -f %{_datadir}/icons/hicolor >/dev/null 2>&1 || true

%postun
/usr/bin/update-desktop-database %{_datadir}/applications >/dev/null 2>&1 || true
/usr/bin/gtk-update-icon-cache -f %{_datadir}/icons/hicolor >/dev/null 2>&1 || true

%files
%{_bindir}/v2rayn
/opt/v2rayN
%{_datadir}/applications/v2rayn.desktop
%{_datadir}/icons/hicolor/256x256/apps/v2rayn.png
SPEC

  sed -i "s/__VERSION__/${VERSION}/g; s/__PKGROOT__/${PKGROOT}/g" "$specfile"
  rpmbuild -ba "$specfile" --target "$rpm_target"

  echo "Build done for ${rid}. RPM at:"
  for f in "${topdir}/RPMS/${archdir}/v2rayN-${VERSION}-1"*.rpm; do
    [[ -e "$f" ]] || continue
    echo "  $f"
    BUILT_RPMS+=("$f")
  done

  trap - RETURN
  rm -rf "$workdir"
}

build_one_target() {
  local short="$1" meta rid rpm_target archdir pubdir
  mapfile -t meta < <(describe_target "$short") || die "Unknown arch '$short' (use x64|arm64)"
  rid="${meta[0]}"
  rpm_target="${meta[1]}"
  archdir="${meta[2]}"

  echo "[*] Building for target: $short  (RID=$rid, RPM --target $rpm_target)"
  pubdir="$(build_publish "$rid")"
  package_rpm "$rid" "$rpm_target" "$archdir" "$pubdir"
}

print_summary() {
  if (( BUILT_ALL == 1 )); then
    echo ""
    echo "================ Build Summary (both architectures) ================"
    if ((${#BUILT_RPMS[@]})); then
      printf '%s\n' "${BUILT_RPMS[@]}"
    else
      echo "No RPMs detected in summary (check build logs above)."
    fi
    echo "===================================================================="
  fi
}

main() {
  parse_args "$@"
  detect_environment
  verify_kernel
  install_dependencies
  enter_workspace
  sync_submodules
  locate_project
  resolve_version
  select_targets

  local arch
  for arch in "${TARGETS[@]}"; do
    build_one_target "$arch"
  done

  print_summary
}

main "$@"
