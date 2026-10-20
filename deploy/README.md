# HomeProxy 一体化部署包（luci + 打补丁内核）

本 ZIP 由 GitHub Actions 自动构建，内含：

- `luci-app-homeproxy.ipk` —— 本仓库用 OpenWrt SDK 编译的 **all 架构** luci 包（含中文 lmo）
- `sing-box` —— **打过补丁的 reF1nd sing-box 1.14.3-reF1nd** 静态二进制（对应架构）
- `install.sh` —— 一键部署脚本
- `README.md` —— 本说明

补丁让内核原生支持 `proxy_providers` 配置与 `/providers/proxies` API，
实现与 Mihomo / OpenClash 一样的「无损对接 Zashboard 面板」（含 WebSocket 实时页）。

---

## 一、怎么拿到这个 ZIP（在 GitHub 上自动编译）

1. 打开你的仓库 **Actions** 页面：
   `https://github.com/<你>/luci-app-homeproxy/actions`
2. 选择工作流 **Build All-in-One Deploy ZIP** → **Run workflow**
3. 填写：
   - `tag`：版本号，例如 `2.0.0`（不需要 `v` 前缀，它会作为包版本与 Release 名）
   - `description`：Release 描述（可选）
4. 等待所有 job 完成（luci 编译 + 4 个架构内核 + 打包，约 15–30 分钟）
5. 到 **Releases** 页面下载对应架构的 zip：
   - `homeproxy-deploy-amd64-<ver>.zip`   → x86_64 路由器
   - `homeproxy-deploy-arm64-<ver>.zip`   → aarch64 路由器
   - `homeproxy-deploy-armv7-<ver>.zip`   → armv7（如 N1、部分 ARM 软路由）
   - `homeproxy-deploy-mipsle-<ver>.zip`  → mipsel（如 MTK 7621/7620 等）

> 说明：luci 包是架构无关的（all），每个 zip 只是内核二进制不同。
> Release tag 为 `deploy-<ver>`，与现有 luci-only 的 Release 互不冲突。

---

## 二、安装（传到路由器 tmp，一条命令装好）

```bash
# 在本机把 zip 传到路由器
scp homeproxy-deploy-amd64-2.0.0.zip root@路由器IP:/tmp/

# SSH 进路由器，一条复合命令：解压 + 进入目录 + 执行安装
ssh root@路由器IP
cd /tmp && unzip -o homeproxy-deploy-amd64-2.0.0.zip && cd homeproxy-deploy-amd64-2.0.0 && sh install.sh
```

`install.sh` 会自动：停服务 → 用 opkg/apk 安装 luci（自动解决依赖，需联网或已配源）→
铺设打补丁内核到 `/usr/bin/sing-box` → 启用并启动 homeproxy → 刷新 LuCI 缓存。

---

## 三、架构对照表

| ZIP 后缀   | 适用 `uname -m`        | 典型设备 |
|------------|------------------------|----------|
| `amd64`    | `x86_64`               | x86 软路由、虚拟机 |
| `arm64`    | `aarch64`              |  ARM64 软路由、N1（用此）、R2S 等 |
| `armv7`    | `armv7l`               | ARMv7 设备 |
| `mipsle`   | `mips` (小端, softfloat)| MTK 7621/7620 等 |

下错架构会在 `install.sh` 铺设内核后运行报错；用 `uname -m` 确认后选对 zip 重来即可。

---

## 四、重要注意事项

1. **不要点面板「更新内核」**：homeproxy 的 `update_core.sh` 会从此包之外的官方源
   重新下载原版内核并覆盖 `/usr/bin/sing-box`，补丁会丢失。要升级请重新跑 `install.sh`。
2. **版本钉死的意义**：二进制版本号被编译为 `1.14.3-reF1nd`，与官方原版一致，因此
   homeproxy 启动时的 `ensure_core` 会判定「已是最新」并**跳过下载**，从而保留补丁。
   若用裸 `go build` 编译导致版本为 `unknown`，会被判定需更新而被覆盖。
3. **luci 依赖**：`opkg install` 会自动拉 `firewall4 / dnsmasq-full / kmod-tun /
   kmod-nft-tproxy / curl / jsonfilter / ucode-*` 等；若你的镜像缺少源，安装会警告，
   需先配好软件源或手动补齐依赖，否则面板/分流不可用。
4. **apk 镜像（OpenWrt 25.12+）**：本包提供的是 `.ipk`（opkg）。apk 镜像请改用仓库
   自带 `build.yml` 出的 `.apk`，再单独部署内核；或后续版本会追加 `.apk` 支持。

---

## 五、验证

部署后：

```bash
sing-box version                                  # 应显示 1.14.3-reF1nd
grep proxy_providers /var/run/homeproxy/sing-box-c.json   # 应有内容
curl -s -H "Authorization: Bearer homeproxy" http://127.0.0.1:9090/providers/proxies  # 返回供应商列表
```

面板上：「代理供应商」页出数据；「概览 / 连接 / 日志」实时页恢复。

---

## 六、内核构建参数（可复现）

```
CGO_ENABLED=0 GOOS=linux GOARCH=<arch> \
go build -trimpath -o sing-box \
  -tags "with_gvisor,with_quic,with_dhcp,with_wireguard,with_utls,with_acme,with_clash_api,with_tailscale,with_ccm,with_ocm,with_cloudflared,with_usbip,with_openvpn,with_openconnect,with_musl" \
  -ldflags "-X 'github.com/sagernet/sing-box/constant.Version=1.14.3-reF1nd' -X runtime.godebugDefault=multipathtcp=0,tlssha1=1 -s -w -buildid=" \
  ./cmd/sing-box
```

（注：刻意去掉了 `with_naive_outbound`，因其依赖 cronet-go 的 musl 预编译 C 库，
无法纯静态编；naive 代理在 homeproxy 订阅中基本不会用到，去掉无影响。）
