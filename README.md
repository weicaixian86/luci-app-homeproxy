适用于 OpenWrt 的 HomeProxy LuCI 管理界面。
HomeProxy 本身为架构无关的 LuCI 包（`LUCI_PKGARCH:=all`），**安装包内不预置任何单一架构的 sing-box 二进制**。运行时由插件根据设备架构，从本仓库的 Release（`weicaixian86/luci-app-homeproxy`）下载对应架构的打补丁内核压缩包（含 clash proxy-providers 补丁），校验后安装到 `/usr/bin/sing-box`。

内核版本固定为 reF1nd 定制内核 `1.14.3-reF1nd`。该内核由本仓库的 `build-deploy.yml` 工作流云端编译（amd64 / arm64 / armv7 / mipsle 四种 Linux musl 架构），并随每个版本发布到**对应版本号的 Release 标签**（例如 `0.1.01`）。注意：发布标签不再固定为 `v1.14.3-reF1nd`，而是每次发布时你输入的版本号；工作流会自动把 `update_core.sh` 里的 `REFIND_TAG` 改写为该标签，因此「更新内核」会从该版本的 Release 拉取打补丁内核（已发布的版本 Release 请不要删除，否则旧版 luci 的自动下载会失效）。

已提供 Linux musl 构建的架构（内核 tar.gz 命名：`sing-box-1.14.3-reF1nd-linux_<版本>-<架构>-musl.tar.gz`，`<版本>` 即发布标签）：
- `x86_64`（`linux_<版本>-amd64-musl`）
- `aarch64`（`linux_<版本>-arm64-musl`）
- `armv7`（如 `linux-armv7-musleabihf`）
- `mipsel`（`linux_<版本>-mipsle-musl`）

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

- `build-deploy.yml`（Build & Release All-in-One）：手动触发，输入版本号（如 `0.1.01`）后，云端编译打补丁的 reF1nd 内核（amd64/arm64/armv7/mipsle）+ luci 包（24.10 IPK 与 25.12 APK）。只发**一个** Release，标签即该版本号，包含：每架构一个一体化 zip（luci 包 + 内核 + install.sh）、独立可装的 `luci-app-homeproxy_<版本>-all.ipk` / `.apk`、以及 `sing-box-1.14.3-reF1nd-linux_<版本>-*-musl.tar.gz`（供「更新内核」自动下载）。构建时会把 `update_core.sh` 的 `REFIND_TAG` 改写为该 Release 标签，因此装 IPK/APK 后也能自动从同一 Release 拉到打补丁内核。
- `Rescan-Translation.yml`：代码变更后自动重新扫描并更新翻译文件，也支持手动运行。
- `Update-Geodata.yml`：每周自动更新内置 geodata 资源，也支持手动运行。

## 四、常见问题

1、面板下载失败解决办法
第一种：面板设置 - UI 下载地址，下拉选择需要的 UI，点击更新面板手动触发面板下载。
第二种：下载面板 ZIP 包，手动上传面板 ZIP，下载地址如下。
镜像
```sh
https://gh-proxy.com/https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip
```
或者直连
```sh
https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip
```

2、远程规则集是否下载成功判断
连接 SSH 查看 `/etc/homeproxy/ruleset/` 目录下是否有规则集文件，有则表示下载成功，反之则没下载成功，检查规则集远程连接。

3、sing-box 内核未安装或下载失败
在 LuCI 状态页「sing-box 内核管理」查看当前架构与目标版本；若显示“未安装”，点击「下载 / 更新内核」。下载日志位于 `/var/run/homeproxy/core_download.log`。若当前架构 reF1nd 暂未发布二进制，请等待作者更新。

4、安装新包后如果页面仍显示旧文字，建议清浏览器缓存，或执行：
```sh
rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache/*
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```

## 五、感谢作者
immortalwrt
https://github.com/immortalwrt/homeproxy

VIKINGYFY
https://github.com/VIKINGYFY/homeproxy

reF1nd（第三方 sing-box 内核源码 / 原始发布）
https://github.com/reF1nd/sing-box-releases
