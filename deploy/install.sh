#!/bin/sh
# =============================================================================
# HomeProxy 一体化部署脚本
#   本目录必须包含：
#     - luci-app-homeproxy.ipk / .apk   （本仓库 CI 用 OpenWrt SDK 编译的 all 架构包；按包管理器选其一）
#     - sing-box                 （打补丁的 reF1nd 内核，版本钉为 1.14.3-reF1nd）
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
else
  echo ":: 错误：未找到 opkg 或 apk，无法安装 luci。"
  echo "   请先手动安装 ./luci-app-homeproxy.ipk，再单独部署内核（把 ./sing-box 拷到 /usr/bin/sing-box）。"
  exit 1
fi
echo "==> 包管理器: $PKG"

# ---- 2. 停止 homeproxy 服务 --------------------------------------------------
echo "==> [1/5] 停止 homeproxy 服务"
/etc/init.d/homeproxy stop 2>/dev/null || true
sleep 1

# ---- 3. 安装 / 重装 luci-app-homeproxy --------------------------------------
echo "==> [2/5] 安装 luci-app-homeproxy（自动解决依赖，需联网或已配置软件源）"
# 按当前包管理器选择对应的包文件（zip 内同时含 .ipk 与 .apk）
case "$PKG" in
  apk)  PKG_FILE="./luci-app-homeproxy.apk" ;;
  opkg) PKG_FILE="./luci-app-homeproxy.ipk" ;;
  *)    PKG_FILE="" ;;
esac
if [ -z "$PKG_FILE" ] || [ ! -f "$PKG_FILE" ]; then
  echo ":: 错误：当前目录缺少 $PKG_FILE"
  echo "   请确认下载的是与本机包管理器匹配的部署包（opkg→.ipk，apk→.apk）。"
  exit 1
fi
# 已安装则先卸载（opkg/apk 默认保留 conffiles，配置不丢），保证可重复执行=升级
$PKG_REMOVE luci-app-homeproxy 2>/dev/null || true
if ! $PKG_INSTALL "$PKG_FILE"; then
  echo ":: 警告：luci 安装失败（多半是软件源不可用或依赖缺失）。"
  echo "   请确认 opkg/apk 源可用后重试；内核仍会照常部署，但 LuCI 页面可能缺失。"
fi

# ---- 4. 部署打补丁的 sing-box 内核 ------------------------------------------
echo "==> [3/5] 部署打补丁的 sing-box 内核（版本钉 1.14.3-reF1nd）"
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

echo ""
echo "===== 部署完成，开始校验 ====="
echo "-- sing-box 版本（应为 1.14.3-reF1nd，与运行时下载跳过条件一致，不会被官方原版覆盖）--"
/usr/bin/sing-box version 2>/dev/null || echo "(sing-box version 读取失败)"
echo ""
echo "-- 配置里是否生成 proxy_providers（内核补丁生效标志）--"
grep -A2 proxy_providers /var/run/homeproxy/sing-box-c.json 2>/dev/null \
  || echo "(配置尚未生成：请到面板『保存并应用』一次，再重启 homeproxy 后重试)"
echo ""
echo "提示："
echo "  1) 面板『更新内核』现在已指向本仓库的 v1.14.3-reF1nd Release（含补丁内核）："
echo "     amd64/arm64 点它会从你的仓库拉补丁版，安全；armv7/mipsle 不在自动下载名单，"
echo "     仍请用本脚本升级（zip 内已含对应内核）。"
echo "  2) 要升级内核/面板时，重新跑本脚本即可（它会再次覆盖 /usr/bin/sing-box 并重装 luci）。"
echo "  3) 面板『代理供应商』页应列出每个订阅的节点/用量/到期；"
echo "     『概览/连接/日志』三个实时页（WebSocket）也应恢复正常。"
