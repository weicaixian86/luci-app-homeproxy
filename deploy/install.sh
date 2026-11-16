#!/bin/sh
# =============================================================================
# HomeProxy 一体化部署脚本
#   本目录必须包含：
#     - luci-app-homeproxy_<版本>-all.apk         （本仓库 CI 编译的 all 架构包）
#       IPK（OpenWrt 24.10 及更早）已不再提供：那些版本内核过低，启用不了 eBPF，请升级到 25.12。
#     - sing-box                 （打补丁的 reF1nd 内核，版本为 1.14.4-reF1nd_<插件版本>）
#     - install.sh / README.md   （本脚本与说明）
#
# 用法（在路由器上，本脚本所在目录内执行）：
#   sh install.sh
#
# 它会：停服务 → 安装 luci（自动解决依赖）→ 铺设打补丁内核 → 启用并启动。
# 反复执行等价于「升级」（先卸旧 luci 保留配置，再装新 luci + 覆盖内核）。
# =============================================================================
set -e

self="$(cd "$(dirname "$0")" && pwd)"
cd "$self"

echo "===== HomeProxy 一体化部署 ====="
echo "工作目录: $self"

# ---- 1. 识别包管理器 --------------------------------------------------------
if command -v apk >/dev/null 2>&1; then
  PKG=apk
  PKG_INSTALL="apk add --allow-untrusted"
  PKG_REMOVE="apk del"
elif command -v opkg >/dev/null 2>&1; then
  PKG=opkg
  PKG_INSTALL="opkg install"
  PKG_REMOVE="opkg remove"
elif command -v opkg >/dev/null 2>&1; then
  echo ":: 错误：检测到 opkg（OpenWrt 24.10 及更早）。本版本已不再提供 .ipk 安装包。"
  echo "   eBPF 透明代理需要 Linux 6.6+ 且内核带 with_ebpf，24.10 内核过低，装上也启用不了。"
  echo "   请升级到 OpenWrt 25.12（apk）后再安装。"
  exit 1
else
  echo ":: 错误：未找到 apk 包管理器，无法安装 luci。"
  echo "   本版本仅支持 OpenWrt 25.12（apk）。"
  exit 1
fi
echo "==> 包管理器: $PKG"

# ---- 2. 停止 homeproxy 服务 --------------------------------------------------
echo "==> [1/5] 停止 homeproxy 服务"
/etc/init.d/homeproxy stop 2>/dev/null || true
sleep 1

# ---- 3. 安装 / 重装 luci-app-homeproxy --------------------------------------
echo "==> [2/5] 安装 luci-app-homeproxy（自动解决依赖，需联网或已配置软件源）"
# 只发 .apk（IPK 已随 24.10 一起退场；文件名带版本号）
case "$PKG" in
  apk)  PKG_EXT="apk" ;;
  *)    PKG_EXT="" ;;
esac
PKG_FILE=""
if [ -n "$PKG_EXT" ]; then
  # 兼容 luci-app-homeproxy_<版本>-all.ipk / 不带版本号的旧命名
  PKG_FILE="$(ls ./luci-app-homeproxy*.${PKG_EXT} 2>/dev/null | head -n1)"
fi
if [ -z "$PKG_FILE" ]; then
  echo ":: 错误：当前目录缺少 luci-app-homeproxy*.${PKG_EXT}"
  echo "   本版本仅提供 .apk（OpenWrt 25.12）。"
  exit 1
fi
# 已安装则先卸载（apk 默认保留 conffiles，配置不丢），保证可重复执行=升级
$PKG_REMOVE luci-app-homeproxy 2>/dev/null || true
if ! $PKG_INSTALL "$PKG_FILE"; then
  echo ":: 警告：luci 安装失败（多半是软件源不可用或依赖缺失）。"
  echo "   请确认 apk 源可用后重试；内核仍会照常部署，但 LuCI 页面可能缺失。"
fi

# ---- 4. 部署打补丁的 sing-box 内核 ------------------------------------------
echo "==> [3/5] 部署打补丁的 sing-box 内核（版本 1.14.4-reF1nd_<插件版本>）"
if [ ! -x ./sing-box ]; then
  echo ":: 错误：当前目录缺少可执行的 ./sing-box"
  exit 1
fi
install -m 0755 ./sing-box /usr/bin/sing-box
chown root:root /usr/bin/sing-box

# ---- 5. 启用并启动，刷新 LuCI 缓存 ------------------------------------------
echo "==> [4/5] 启用并启动 homeproxy"
/etc/init.d/homeproxy enable 2>/dev/null || true
/etc/init.d/homeproxy start
sleep 2
# 让 LuCI 重新扫描到新装的 app
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null || true
/etc/init.d/uhttpd restart 2>/dev/null || true
# rpcd 只在启动时加载 /usr/share/rpcd/ucode/*.uc，不重启就仍是旧方法表：
# 新版本新增的 RPC（如 dns_server_test 延迟测试）会一律报 Method not found。
/etc/init.d/rpcd restart 2>/dev/null || service rpcd restart 2>/dev/null || true

echo ""
echo "===== 部署完成，开始校验 ====="
echo "-- sing-box 版本（应为 1.14.4-reF1nd_<插件版本>，如 1.14.4-reF1nd_0.4.0；下载跳过条件只比对下划线前的基础版本）--"
/usr/bin/sing-box version 2>/dev/null || echo "(sing-box version 读取失败)"
echo ""
echo "-- 配置里是否生成 proxy_providers（内核补丁生效标志）--"
grep -A2 proxy_providers /var/run/homeproxy/sing-box-c.json 2>/dev/null \
  || echo "(配置尚未生成：请到面板『保存并应用』一次，再重启 homeproxy 后重试)"
echo ""
echo "提示："
echo "  1) 面板『更新内核』指向本次发布标签的 Release（如 0.1.01，含补丁内核）："
echo "     amd64/arm64 点它会从你的仓库拉补丁版，安全（0.4.0 起不再构建 armv7/mipsle）。"
echo "  2) 要升级内核/面板时，重新跑本脚本即可（它会再次覆盖 /usr/bin/sing-box 并重装 luci）。"
echo "  3) 面板『代理供应商』页应列出每个订阅的节点/用量/到期；"
echo "     『概览/连接/日志』三个实时页（WebSocket）也应恢复正常。"
