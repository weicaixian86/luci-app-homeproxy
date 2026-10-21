# HomeProxy for OpenWrt

适用于 OpenWrt 的 HomeProxy LuCI 管理界面（基于 immortalwrt/homeproxy 修改）。

安装包为架构无关的 LuCI 包（`LUCI_PKGARCH:=all`），**不含 sing-box 二进制**。装好后，插件会按设备架构从本仓库 Releases 自动下载**打补丁的 reF1nd 内核**（`1.14.3-reF1nd`，含 clash proxy-providers 补丁）并安装到 `/usr/bin/sing-box`。

支持架构：amd64 / arm64 / armv7 / mipsle（Linux musl）。

## 版本与内核说明
- 每次发布时你输入的版本号即为 Release 标签（如 `0.1.1`），一个版本对应一个 Release。
- 工作流 `build-deploy.yml` 会把 `update_core.sh` 的 `REFIND_TAG` 改写为该标签，因此「更新内核」从同一 Release 拉补丁内核。
- ⚠️ 已发布的 Release 不要删除，否则旧版用户「更新内核」会失效。

## 一、安装

HomeProxy 提供两种安装方式。**先确认路由器系统版本**：OpenWrt 24.10 用 `opkg` + `.ipk`，OpenWrt 25.12 用 `apk` + `.apk`。所有安装包均来自本仓库的 **Releases** 页面（每个版本一个 Release 标签，如 `0.1.01`）。

### 方式一：安装 IPK / APK，内核自动下载（推荐，在线）

适合能联网、已配置软件源的路由器。装好面板后，打补丁的 reF1nd 内核会按设备架构自动下载并安装。

1. 到 Releases 下载与系统对应的包（`<版本>` 替换成实际发布号，如 `0.1.01`）：
   - OpenWrt **24.10** → `luci-app-homeproxy_<版本>-all.ipk`
   - OpenWrt **25.12** → `luci-app-homeproxy_<版本>-all.apk`
2. 上传到路由器 `/tmp`，按系统安装：

   - 24.10（`opkg`）：
     ```sh
     opkg update && opkg install /tmp/luci-app-homeproxy_<版本>-all.ipk
     ```
   - 25.12（`apk`）：
     ```sh
     apk --update-cache add --allow-untrusted /tmp/luci-app-homeproxy_<版本>-all.apk
     ```

3. 首次启动服务时，插件会按架构自动下载并安装 reF1nd sing-box 内核（`1.14.3-reF1nd`，含 clash proxy-providers 补丁）；也可以在 LuCI 状态页「sing-box 内核管理」中手动点「下载 / 更新内核」。
4. 刷新浏览器（必要时清缓存，或 `rm -f /tmp/luci-indexcache && rm -rf /tmp/luci-modulecache/* && /etc/init.d/rpcd restart && /etc/init.d/uhttpd restart`）即可看到 HomeProxy 菜单。

> 说明：方式一装好后，面板「更新内核」会从**本仓库对应版本 Release**（即你装包时那个标签）拉补丁版内核，不会覆盖补丁；amd64 / arm64 / armv7 / mipsle 四种架构均已纳入自动下载。

### 方式二：下载 ZIP 离线安装（含内核，无需额外下载）

适合无法联网拉取内核、或希望一次性铺好「面板 + 内核」的路由器。每个架构一个 zip，内含 luci 包（`.ipk` 与 `.apk` 都有）、打补丁内核 `sing-box`、`install.sh` 与说明。

1. 到 Releases 下载对应架构的 zip（按 `uname -m` 选择；`<版本>` 为实际发布号）：
   - `x86_64`  → `homeproxy-deploy_<版本>-amd64.zip`
   - `aarch64` → `homeproxy-deploy_<版本>-arm64.zip`
   - `armv7`   → `homeproxy-deploy_<版本>-armv7.zip`
   - `mipsel`  → `homeproxy-deploy_<版本>-mipsle.zip`
2. 传到路由器并安装（`install.sh` 会自动识别当前包管理器、选用 zip 内对应的 `.ipk` 或 `.apk`）：

   ```sh
   scp homeproxy-deploy_<版本>-amd64.zip root@路由器IP:/tmp/
   ssh root@路由器IP
   cd /tmp && unzip -o homeproxy-deploy_<版本>-amd64.zip && cd homeproxy-deploy_<版本>-amd64 && sh install.sh
   ```

3. `install.sh` 会自动执行：停服务 → 安装 luci（opkg/apk 自动解决依赖，需联网或已配源）→ 铺设 `/usr/bin/sing-box` 内核 → 启动服务 → 刷新 LuCI。升级时重新跑本脚本即可（会再次覆盖内核并重装 luci）。

> 两种方式下内核版本都钉死为 `1.14.3-reF1nd`（打过补丁），因此 `ensure_core` 会判定「已是最新」并跳过下载，从而保留补丁。

## 二、卸载

```sh
/etc/init.d/homeproxy stop 2>/dev/null || true
/etc/init.d/homeproxy disable 2>/dev/null || true
opkg remove luci-app-homeproxy 2>/dev/null || true
# OpenWrt 25.12 使用 apk remove luci-app-homeproxy
rm -rf /etc/config/homeproxy
rm -rf /etc/homeproxy
rm -rf /usr/share/homeproxy
rm -rf /www/luci-static/resources/view/homeproxy
rm -f /www/luci-static/resources/homeproxy.js
rm -f /usr/share/luci/menu.d/luci-app-homeproxy.json
rm -f /usr/share/rpcd/acl.d/luci-app-homeproxy.json
rm -f /usr/share/rpcd/ucode/luci.homeproxy
rm -f /usr/bin/sing-box
rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache/*
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```

## 三、维护工作流

- `build-deploy.yml`（Build & Release All-in-One）：手动触发，输入版本号（如 `0.1.1`）后云端编译打补丁 reF1nd 内核（amd64/arm64/armv7/mipsle）+ luci 包（24.10 IPK 与 25.12 APK）。只发**一个** Release，标签即该版本号，包含：每架构一体化 zip、`luci-app-homeproxy_<版本>-all.ipk/.apk`、以及 `sing-box-1.14.3-refind_<版本>-linux-*-musl.tar.gz`（供「更新内核」自动下载）。
- `Rescan-Translation.yml`：代码变更后自动/手动更新翻译。
- `Update-Geodata.yml`：每周自动/手动更新内置 geodata。

## 四、常见问题

1. **面板下载失败**
   - 面板设置 → UI 下载地址，下拉选 UI 后点「更新面板」手动触发；
   - 或手动下载 ZIP 上传：`https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip`（可加 `https://gh-proxy.com/` 前缀走镜像）。

2. **远程规则集是否下载成功**
   SSH 查看 `/etc/homeproxy/ruleset/` 是否有文件：有即成功，否则检查规则集远程连接。

3. **sing-box 内核未安装或下载失败**
   LuCI 状态页「sing-box 内核管理」查看架构与目标版本；显示"未安装"则点「下载 / 更新内核」。日志：`/var/run/homeproxy/core_download.log`。若当前架构 reF1nd 暂未发布，请等作者更新。

4. **装新包后页面仍是旧文字**
   清浏览器缓存，或执行：
   ```sh
   rm -f /tmp/luci-indexcache
   rm -rf /tmp/luci-modulecache/*
   /etc/init.d/rpcd restart
   /etc/init.d/uhttpd restart
   ```

## 五、感谢作者
- immortalwrt：https://github.com/immortalwrt/homeproxy
- VIKINGYFY：https://github.com/VIKINGYFY/homeproxy
- reF1nd（第三方 sing-box 内核）：https://github.com/reF1nd/sing-box-releases
