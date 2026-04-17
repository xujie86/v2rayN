#!/usr/bin/env bash
set -euo pipefail

VERSION_ARG="${1:-}"
WITH_CORE="both"
FORCE_NETCORE=0
ARCH_OVERRIDE=""
BUILD_FROM=""

XRAY_VER="${XRAY_VER:-}"
SING_VER="${SING_VER:-}"

MIN_KERNEL="6.11"

PROJECT=""
SCRIPT_DIR=""
VERSION=""
HOST_ARCH=""
BUILT_ALL=0
BUILT_DEBS=()
OUTPUT_DIR="$HOME/debbuild"

if [[ "${VERSION_ARG:-}" == --* ]]; then
  VERSION_ARG=""
fi
if [[ -n "${VERSION_ARG:-}" ]]; then
  shift || true
fi

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with-core)   WITH_CORE="${2:-both}"; shift 2 ;;
      --xray-ver)    XRAY_VER="${2:-}"; shift 2 ;;
      --singbox-ver) SING_VER="${2:-}"; shift 2 ;;
      --netcore)     FORCE_NETCORE=1; shift ;;
      --arch)        ARCH_OVERRIDE="${2:-}"; shift 2 ;;
      --buildfrom)   BUILD_FROM="${2:-}"; shift 2 ;;
      *)
        if [[ -z "${VERSION_ARG:-}" ]]; then
          VERSION_ARG="$1"
        fi
        shift
        ;;
    esac
  done

  if [[ -n "${VERSION_ARG:-}" && -n "${BUILD_FROM:-}" ]]; then
    echo "You cannot specify both an explicit version and --buildfrom at the same time."
    echo "        Provide either a version (e.g. 7.14.0) OR --buildfrom 1|2|3."
    exit 1
  fi
}

detect_environment() {
  . /etc/os-release

  case "${ID:-}" in
    debian)
      echo "Detected supported system: ${NAME:-$ID} ${VERSION_ID:-}"
      ;;
    *)
      echo "Unsupported system: ${NAME:-unknown} (${ID:-unknown})."
      echo "This script only supports: Debian."
      exit 1
      ;;
  esac

  HOST_ARCH="$(uname -m)"
  case "$HOST_ARCH" in
    x86_64|aarch64) ;;
    *)
      echo "Only supports aarch64 / x86_64"
      exit 1
      ;;
  esac

  local current_kernel lowest
  current_kernel="$(uname -r)"
  lowest="$(printf '%s\n%s\n' "$MIN_KERNEL" "$current_kernel" | sort -V | head -n1)"
  if [[ "$lowest" != "$MIN_KERNEL" ]]; then
    echo "Kernel $current_kernel is below $MIN_KERNEL"
    exit 1
  fi

  echo "[OK] Kernel $current_kernel verified."
}

foreign_arch_for_host() {
  case "$1" in
    x86_64)  echo "arm64" ;;
    aarch64) echo "amd64" ;;
    *)       return 1 ;;
  esac
}

install_dependencies() {
  local install_ok=0
  local foreign_arch=""

  mkdir -p "$OUTPUT_DIR"

  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get -y install \
      curl unzip tar jq rsync ca-certificates git dpkg-dev fakeroot file \
      desktop-file-utils xdg-utils wget

    foreign_arch="$(foreign_arch_for_host "$HOST_ARCH")"
    [[ -n "$foreign_arch" ]] || { echo "Only supports aarch64 / x86_64"; exit 1; }

    sudo dpkg --add-architecture "$foreign_arch" || true
    sudo apt-get update
    sudo apt-get -y install \
      "libc6:${foreign_arch}" \
      "libgcc-s1:${foreign_arch}" \
      "libstdc++6:${foreign_arch}" \
      "zlib1g:${foreign_arch}" \
      "libfontconfig1:${foreign_arch}"

    wget -q https://dot.net/v1/dotnet-install.sh
    chmod +x dotnet-install.sh
    ./dotnet-install.sh --channel 8.0 --install-dir "$HOME/.dotnet"

    export PATH="$HOME/.dotnet:$PATH"
    export DOTNET_ROOT="$HOME/.dotnet"

    dotnet --info >/dev/null 2>&1 && install_ok=1
  fi

  if [[ "$install_ok" -ne 1 ]]; then
    echo "Could not auto-install dependencies for '$ID'. Make sure these are available:"
    echo "dotnet-sdk 8.x, curl, unzip, tar, rsync, git, dpkg-deb, desktop-file-utils, xdg-utils"
    exit 1
  fi
}

prepare_workspace() {
  SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  cd "$SCRIPT_DIR"

  if [[ -f .gitmodules ]]; then
    git submodule sync --recursive || true
    git submodule update --init --recursive || true
  fi

  PROJECT="v2rayN.Desktop/v2rayN.Desktop.csproj"
  if [[ ! -f "$PROJECT" ]]; then
    PROJECT="$(find . -maxdepth 3 -name 'v2rayN.Desktop.csproj' | head -n1 || true)"
  fi
  [[ -f "$PROJECT" ]] || { echo "v2rayN.Desktop.csproj not found"; exit 1; }
}

choose_channel() {
  if [[ -n "${BUILD_FROM:-}" ]]; then
    case "$BUILD_FROM" in
      1) echo "latest"; return 0 ;;
      2) echo "prerelease"; return 0 ;;
      3) echo "keep"; return 0 ;;
      *) echo "[ERROR] Invalid --buildfrom value: ${BUILD_FROM}. Use 1|2|3." >&2; exit 1 ;;
    esac
  fi

  local ch="latest" sel=""
  if [[ -t 0 ]]; then
    echo "[?] Choose v2rayN release channel:" >&2
    echo "    1) Latest (stable)  [default]" >&2
    echo "    2) Pre-release (preview)" >&2
    echo "    3) Keep current (do nothing)" >&2
    printf "Enter 1, 2 or 3 [default 1]: " >&2
    if read -r sel </dev/tty; then
      case "${sel:-}" in
        2) ch="prerelease" ;;
        3) ch="keep" ;;
      esac
    fi
  fi
  echo "$ch"
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
  local want="$1" ref=""

  if git rev-parse --git-dir >/dev/null 2>&1; then
    git fetch --tags --force --prune --depth=1 || true
    if git rev-parse "refs/tags/${want}" >/dev/null 2>&1; then
      ref="${want}"
    fi
    if [[ -n "$ref" ]]; then
      echo "[OK] Found ref '${ref}', checking out..."
      git checkout -f "${ref}"
      if [[ -f .gitmodules ]]; then
        git submodule sync --recursive || true
        git submodule update --init --recursive || true
      fi
      return 0
    fi
  fi

  return 1
}

apply_channel_or_keep() {
  local ch="$1" tag=""

  if [[ "$ch" == "keep" ]]; then
    echo "[*] Keep current repository state (no checkout)."
    VERSION="$(git describe --tags --abbrev=0 2>/dev/null || echo '0.0.0+git')"
    VERSION="${VERSION#v}"
    return 0
  fi

  echo "[*] Resolving ${ch} tag from GitHub releases..."
  case "$ch" in
    prerelease) tag="$(get_latest_tag_prerelease || true)" ;;
    latest)     tag="$(get_latest_tag_latest || true)" ;;
    *)          echo "Failed to resolve latest tag for channel '${ch}'."; exit 1 ;;
  esac

  [[ -n "$tag" ]] || { echo "Failed to resolve latest tag for channel '${ch}'."; exit 1; }
  echo "[*] Latest tag for '${ch}': ${tag}"
  git_try_checkout "$tag" || { echo "Failed to checkout '${tag}'."; exit 1; }
  VERSION="${tag#v}"
}

resolve_version() {
  if git rev-parse --git-dir >/dev/null 2>&1; then
    if [[ -n "${VERSION_ARG:-}" ]]; then
      local clean_ver
      clean_ver="${VERSION_ARG#v}"
      if git_try_checkout "$clean_ver"; then
        VERSION="$clean_ver"
      else
        echo "[WARN] Tag '${VERSION_ARG}' not found."
        apply_channel_or_keep "$(choose_channel)"
      fi
    else
      apply_channel_or_keep "$(choose_channel)"
    fi
  else
    echo "Current directory is not a git repo; proceeding on current tree."
    VERSION="${VERSION_ARG:-0.0.0}"
  fi

  VERSION="${VERSION#v}"
  echo "[*] GUI version resolved as: ${VERSION}"
}

map_target_meta() {
  local short="$1"

  case "$short" in
    x64)
      TARGET_RID="linux-x64"
      TARGET_DEB_ARCH="amd64"
      TARGET_OUTPUT_ARCH="amd64"
      TARGET_BUNDLE_NAME="v2rayN-linux-64.zip"
      TARGET_XRAY_FILE="Xray-linux-64.zip"
      TARGET_SINGBOX_FILE="sing-box-\${ver}-linux-amd64.tar.gz"
      ;;
    arm64)
      TARGET_RID="linux-arm64"
      TARGET_DEB_ARCH="arm64"
      TARGET_OUTPUT_ARCH="arm64"
      TARGET_BUNDLE_NAME="v2rayN-linux-arm64.zip"
      TARGET_XRAY_FILE="Xray-linux-arm64-v8a.zip"
      TARGET_SINGBOX_FILE="sing-box-\${ver}-linux-arm64.tar.gz"
      ;;
    *)
      echo "Unknown arch '$short' (use x64|arm64)"
      return 1
      ;;
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

  case "$rid" in
    linux-x64)   url="https://github.com/XTLS/Xray-core/releases/download/v${ver}/Xray-linux-64.zip" ;;
    linux-arm64) url="https://github.com/XTLS/Xray-core/releases/download/v${ver}/Xray-linux-arm64-v8a.zip" ;;
    *)           echo "[xray] Unsupported RID: $rid"; return 1 ;;
  esac

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

  case "$rid" in
    linux-x64)   url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-amd64.tar.gz" ;;
    linux-arm64) url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-arm64.tar.gz" ;;
    *)           echo "[sing-box] Unsupported RID: $rid"; return 1 ;;
  esac

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
  local outroot="$1"
  mkdir -p "$outroot/bin"

  local names=(
    geosite.dat
    geoip.dat
    geoip-only-cn-private.dat
    Country.mmdb
    geoip.metadb
  )

  local n
  for n in "${names[@]}"; do
    if [[ -f "$outroot/bin/xray/$n" ]]; then
      mv -f "$outroot/bin/xray/$n" "$outroot/bin/$n"
    fi
  done
}

download_geo_assets() {
  local outroot="$1"
  local bin_dir="$outroot/bin"
  local srss_dir="$bin_dir/srss"

  mkdir -p "$bin_dir" "$srss_dir"

  echo "[+] Download Xray Geo to ${bin_dir}"
  curl -fsSL -o "$bin_dir/geosite.dat" "https://github.com/Loyalsoldier/V2ray-rules-dat/releases/latest/download/geosite.dat"
  curl -fsSL -o "$bin_dir/geoip.dat" "https://github.com/Loyalsoldier/V2ray-rules-dat/releases/latest/download/geoip.dat"
  curl -fsSL -o "$bin_dir/geoip-only-cn-private.dat" "https://raw.githubusercontent.com/Loyalsoldier/geoip/release/geoip-only-cn-private.dat"
  curl -fsSL -o "$bin_dir/Country.mmdb" "https://raw.githubusercontent.com/Loyalsoldier/geoip/release/Country.mmdb"

  echo "[+] Download sing-box rule DB & rule-sets"
  curl -fsSL -o "$bin_dir/geoip.metadb" "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geoip.metadb" || true

  local f
  for f in \
    geoip-private.srs geoip-cn.srs geoip-facebook.srs geoip-fastly.srs \
    geoip-google.srs geoip-netflix.srs geoip-telegram.srs geoip-twitter.srs
  do
    curl -fsSL -o "$srss_dir/$f" "https://raw.githubusercontent.com/2dust/sing-box-rules/rule-set-geoip/$f" || true
  done

  for f in \
    geosite-cn.srs geosite-gfw.srs geosite-google.srs geosite-greatfire.srs \
    geosite-geolocation-cn.srs geosite-category-ads-all.srs geosite-private.srs
  do
    curl -fsSL -o "$srss_dir/$f" "https://raw.githubusercontent.com/2dust/sing-box-rules/rule-set-geosite/$f" || true
  done

  unify_geo_layout "$outroot"
}

populate_assets_zip_mode() {
  local outroot="$1" rid="$2" url="" tmp="" nested_dir=""

  case "$rid" in
    linux-x64)   url="https://raw.githubusercontent.com/2dust/v2rayN-core-bin/refs/heads/master/v2rayN-linux-64.zip" ;;
    linux-arm64) url="https://raw.githubusercontent.com/2dust/v2rayN-core-bin/refs/heads/master/v2rayN-linux-arm64.zip" ;;
    *)           echo "[!] Bundle unsupported RID: $rid"; return 1 ;;
  esac

  echo "[+] Try v2rayN bundle archive: $url"
  tmp="$(mktemp -d)"
  curl -fL "$url" -o "$tmp/v2rayn.zip" || { echo "[!] Bundle download failed"; rm -rf "$tmp"; return 1; }
  unzip -q "$tmp/v2rayn.zip" -d "$tmp" || { echo "[!] Bundle unzip failed"; rm -rf "$tmp"; return 1; }

  if [[ -d "$tmp/bin" ]]; then
    mkdir -p "$outroot/bin"
    rsync -a "$tmp/bin/" "$outroot/bin/"
  else
    rsync -a "$tmp/" "$outroot/"
  fi

  rm -f "$outroot/v2rayn.zip" 2>/dev/null || true
  find "$outroot" -type d -name "mihomo" -prune -exec rm -rf {} + 2>/dev/null || true

  nested_dir="$(find "$outroot" -maxdepth 1 -type d -name 'v2rayN-linux-*' | head -n1 || true)"
  if [[ -n "$nested_dir" && -d "$nested_dir/bin" ]]; then
    mkdir -p "$outroot/bin"
    rsync -a "$nested_dir/bin/" "$outroot/bin/"
    rm -rf "$nested_dir"
  fi

  unify_geo_layout "$outroot"
  rm -rf "$tmp"

  echo "[+] Bundle extracted to $outroot"
}

populate_assets_netcore_mode() {
  local outroot="$1" rid="$2"

  if [[ "$WITH_CORE" == "xray" || "$WITH_CORE" == "both" ]]; then
    download_xray "$outroot/bin/xray" "$rid" || echo "[!] xray download failed (skipped)"
  fi

  if [[ "$WITH_CORE" == "sing-box" || "$WITH_CORE" == "both" ]]; then
    download_singbox "$outroot/bin/sing_box" "$rid" || echo "[!] sing-box download failed (skipped)"
  fi

  download_geo_assets "$outroot" || echo "[!] Geo rules download failed (skipped)"
}

stage_runtime_assets() {
  local outroot="$1" rid="$2"

  mkdir -p "$outroot/bin/xray" "$outroot/bin/sing_box"

  if [[ "$FORCE_NETCORE" -eq 0 ]]; then
    if populate_assets_zip_mode "$outroot" "$rid"; then
      echo "[*] Using v2rayN bundle bin assets."
    else
      echo "[*] Bundle failed, fallback to separate core + rules."
      populate_assets_netcore_mode "$outroot" "$rid"
    fi
  else
    echo "[*] --netcore specified: use separate core + rules."
    populate_assets_netcore_mode "$outroot" "$rid"
  fi
}

select_targets() {
  case "${ARCH_OVERRIDE:-}" in
    all)           targets=(x64 arm64); BUILT_ALL=1 ;;
    x64|amd64)     targets=(x64) ;;
    arm64|aarch64) targets=(arm64) ;;
    "")            targets=($([[ "$HOST_ARCH" == "aarch64" ]] && echo arm64 || echo x64)) ;;
    *)             echo "Unknown --arch '${ARCH_OVERRIDE}'. Use x64|arm64|all."; exit 1 ;;
  esac
}

build_binary() {
  local rid="$1"

  dotnet clean "$PROJECT" -c Release
  rm -rf "$(dirname "$PROJECT")/bin/Release/net8.0" || true
  dotnet restore "$PROJECT"
  dotnet publish "$PROJECT" -c Release -r "$rid" -p:PublishSingleFile=false -p:SelfContained=true
}

package_deb() {
  local rid="$1" deb_arch="$2"
  local pkgroot="v2rayN-publish"
  local workdir stage debian_dir pubdir project_dir icon_candidate deb_out
  local shlibs_depends="" extra_depends="" final_depends="" multiarch="" sys_libdir="" sys_usrlibdir=""

  pubdir="$(dirname "$PROJECT")/bin/Release/net8.0/${rid}/publish"
  [[ -d "$pubdir" ]] || { echo "Publish directory not found: $pubdir"; return 1; }

  workdir="$(mktemp -d)"
  stage="$workdir/${pkgroot}_${VERSION}_${deb_arch}"
  debian_dir="$stage/DEBIAN"

  mkdir -p "$stage/opt/v2rayN" "$stage/usr/bin" "$stage/usr/share/applications" "$stage/usr/share/icons/hicolor/256x256/apps" "$debian_dir"
  cp -a "$pubdir/." "$stage/opt/v2rayN/"

  project_dir="$(cd "$(dirname "$PROJECT")" && pwd)"
  icon_candidate="$project_dir/v2rayN.png"
  [[ -f "$icon_candidate" ]] && cp "$icon_candidate" "$stage/usr/share/icons/hicolor/256x256/apps/v2rayn.png" || true

  stage_runtime_assets "$stage/opt/v2rayN" "$rid"

  install -m 755 /dev/stdin "$stage/usr/bin/v2rayn" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
DIR="/opt/v2rayN"
cd "$DIR"

if [[ -x "$DIR/v2rayN" ]]; then
  exec "$DIR/v2rayN" "$@"
fi

for dll in v2rayN.Desktop.dll v2rayN.dll; do
  if [[ -f "$DIR/$dll" ]]; then
    exec /usr/bin/dotnet "$DIR/$dll" "$@"
  fi
done

echo "v2rayN launcher: no executable found in $DIR" >&2
ls -l "$DIR" >&2 || true
exit 1
EOF

  install -m 644 /dev/stdin "$stage/usr/share/applications/v2rayn.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=v2rayN
Comment=v2rayN for Debian GNU Linux
Exec=v2rayn
Icon=v2rayn
Terminal=false
Categories=Network;
EOF

  extra_depends="libc6 (>= 2.34), fontconfig (>= 2.13.1), desktop-file-utils (>= 0.26), xdg-utils (>= 1.1.3), coreutils (>= 8.32), bash (>= 5.1), libfreetype6 (>= 2.11)"

  multiarch="$(dpkg-architecture -a"$deb_arch" -qDEB_HOST_MULTIARCH)"
  sys_libdir="/lib/$multiarch"
  sys_usrlibdir="/usr/lib/$multiarch"

  : > "$debian_dir/substvars"

  mapfile -t ELF_FILES < <(
    find "$stage/opt/v2rayN" -type f \( -name "*.so*" -o -perm -111 \) ! -name 'libcoreclrtraceptprovider.so'
  )

  if [[ "${#ELF_FILES[@]}" -gt 0 ]]; then
    (
      cd "$workdir"
      dpkg-shlibdeps \
        -l"$stage/opt/v2rayN" \
        -l"$sys_libdir" \
        -l"$sys_usrlibdir" \
        -T"$debian_dir/substvars" \
        "${ELF_FILES[@]}"
    ) >/dev/null 2>&1 || true
  fi

  shlibs_depends="$(sed -n 's/^shlibs:Depends=//p' "$debian_dir/substvars" | head -n1 || true)"
  if [[ -n "$shlibs_depends" ]]; then
    shlibs_depends="$(echo "$shlibs_depends" \
      | sed -E 's/ *\([^)]*\)//g' \
      | sed -E 's/ *, */, /g' \
      | sed -E 's/^, *//; s/, *$//')"
    final_depends="${shlibs_depends}, ${extra_depends}"
  else
    final_depends="${extra_depends}"
  fi

  cat > "$debian_dir/control" <<EOF
Package: v2rayn
Version: ${VERSION}
Architecture: ${deb_arch}
Maintainer: 2dust <noreply@github.com>
Homepage: https://github.com/2dust/v2rayN
Section: net
Priority: optional
Depends: ${final_depends}
Description: v2rayN (Avalonia) GUI client for Linux
 Support vless / vmess / Trojan / http / socks / Anytls / Hysteria2 /
 Shadowsocks / tuic / WireGuard.
EOF

  install -m 755 /dev/stdin "$debian_dir/postinst" <<'EOF'
#!/bin/sh
set -e
update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f /usr/share/icons/hicolor >/dev/null 2>&1 || true
fi
exit 0
EOF

  install -m 755 /dev/stdin "$debian_dir/postrm" <<'EOF'
#!/bin/sh
set -e
update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f /usr/share/icons/hicolor >/dev/null 2>&1 || true
fi
exit 0
EOF

  find "$stage/opt/v2rayN" -type d -exec chmod 0755 {} +
  find "$stage/opt/v2rayN" -type f -exec chmod 0644 {} +
  [[ -f "$stage/opt/v2rayN/v2rayN" ]] && chmod 0755 "$stage/opt/v2rayN/v2rayN" || true

  deb_out="$OUTPUT_DIR/v2rayn_${VERSION}_${deb_arch}.deb"
  dpkg-deb --root-owner-group --build "$stage" "$deb_out"

  echo "Build done for ${rid}. DEB at:"
  echo "  $deb_out"
  BUILT_DEBS+=("$deb_out")

  rm -rf "$workdir"
}

build_one_target() {
  local short="$1"
  local TARGET_RID="" TARGET_DEB_ARCH="" TARGET_OUTPUT_ARCH="" TARGET_BUNDLE_NAME="" TARGET_XRAY_FILE="" TARGET_SINGBOX_FILE=""

  map_target_meta "$short" || return 1

  echo "[*] Building for target: $short  (RID=$TARGET_RID, DEB arch=$TARGET_DEB_ARCH)"
  build_binary "$TARGET_RID"
  package_deb "$TARGET_RID" "$TARGET_DEB_ARCH"
}

print_summary() {
  echo ""
  echo "================ Build Summary ================="
  if [[ "${#BUILT_DEBS[@]}" -gt 0 ]]; then
    echo "Output directory: $OUTPUT_DIR"
    local pkg
    for pkg in "${BUILT_DEBS[@]}"; do
      echo "$pkg"
    done
  else
    echo "No DEBs detected in summary (check build logs above)."
  fi
  echo "==============================================="
}

main() {
  parse_args "$@"
  detect_environment
  install_dependencies
  prepare_workspace
  resolve_version
  select_targets

  local arch
  for arch in "${targets[@]}"; do
    build_one_target "$arch"
  done

  print_summary
}

main "$@"
