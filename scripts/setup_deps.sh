#!/usr/bin/env bash
# Fetch third-party sources required by the HarmonyOS Moonlight port.
# GitHub is not reachable directly in some networks, so mirrors are used
# by default. Override with MOONLIGHT_GIT_BASE / GH_PROXY if needed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TP="$ROOT/entry/src/main/cpp/third_party"
MC_MIRROR="${MOONLIGHT_GIT_BASE:-https://gitcode.com/gh_mirrors/mo/moonlight-common-c.git}"
GH_PROXY="${GH_PROXY:-https://ghfast.top/https://github.com}"

mkdir -p "$TP"

MBEDTLS_TAG="${MBEDTLS_TAG:-v3.6.8}"

clone() { # name url dir [tag]
  local name="$1" url="$2" dir="$3" tag="${4:-}"
  # 工程内 third_party 为 vendored 源码（已打补丁），目录非空即视为已就绪。
  # 注意：不能再用 .git 判断，.git 元数据已移除，否则会 rm -rf 后重新 clone，冲掉本地补丁。
  if [ -d "$TP/$dir" ] && [ -n "$(ls -A "$TP/$dir" 2>/dev/null)" ]; then
    echo "[skip] $name already present"
    return
  fi
  echo "[clone] $name <- $url"
  rm -rf "$TP/$dir"
  if [ -n "$tag" ]; then
    git clone --depth 1 --branch "$tag" "$url" "$TP/$dir"
  else
    git clone --depth 1 "$url" "$TP/$dir"
  fi
  echo "[ok] $name"
}

clone moonlight-common-c "$MC_MIRROR" moonlight-common-c
clone enet               "$GH_PROXY/cgutman/enet.git" enet
clone nanors             "$GH_PROXY/sleepybishop/nanors.git" nanors
clone mbedtls            "$GH_PROXY/Mbed-TLS/mbedtls.git" mbedtls "$MBEDTLS_TAG"
clone opus               "$GH_PROXY/xiph/opus.git" opus

# mbedtls 3.6.x CMake requires the mbedtls-framework submodule.
if [ -d "$TP/mbedtls" ] && [ ! -f "$TP/mbedtls/framework/CMakeLists.txt" ]; then
  echo "[submodule] mbedtls framework"
  git -C "$TP/mbedtls" -c submodule.framework.url="$GH_PROXY/Mbed-TLS/mbedtls-framework.git" \
      submodule update --init --depth 1 framework
fi

echo
echo "Pinned commits:"
for d in moonlight-common-c enet nanors mbedtls opus; do
  if [ -d "$TP/$d/.git" ]; then
    printf "  %-22s %s\n" "$d" "$(git -C "$TP/$d" rev-parse --short HEAD)"
  fi
done
