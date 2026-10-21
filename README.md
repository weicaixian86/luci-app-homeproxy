适用于 OpenWrt 的 HomeProxy LuCI 管理界面。
HomeProxy 本身为架构无关的 LuCI 包（`LUCI_PKGARCH:=all`），**安装包内不预置任何单一架构的 sing-box 二进制**。运行时由插件根据设备架构，从本仓库的 Release（`weicaixian86/luci-app-homeproxy`）下载对应架构的打补丁内核压缩包（含 clash proxy-providers 补丁），校验后安装到 `/usr/bin/sing-box`。

内核版本固定为 reF1nd 定制内核 `1.14.3-reF1nd`。该内核由本仓库的 `build-deploy.yml` 工作流云端编译（amd64 / arm64 / armv7 / mipsle 四种 Linux musl 架构），并随每个版本发布到**对应版本号的 Release 标签**（例如 `0.1.01`）。注意：发布标签不再固定为 `v1.14.3-reF1nd`，而是每次发布时你输入的版本号；工作流会自动把 `update_core.sh` 里的 `REFIND_TAG` 改写为该标签，因此「更新内核」会从该版本的 Release 拉取打补丁内核（已发布的版本 Release 请不要删除，否则旧版 luci 的自动下载会失效）。

已提供 Linux musl 构建的架构：
- `x86_64`（`linux-amd64-musl`）
- `aarch64`（`linux-arm64-musl`）
- `armv7`（如 `linux-armv7-musleabihf`）
- `mipsel`（`linux-mipsle-musl`）

## 一、安装

上传ipk或apk至tmp目录：
- OpenWrt 24.10 使用 `opkg` 安装 `.ipk`：
  ```sh
  opkg update && opkg install /tmp/luci-app-homeproxy_<版本>-all.ipk
  ```
- OpenWrt 25.12 使用 `apk` 安装 `.apk`：
  ```sh
  apk --update-cache add --allow-untrusted /tmp/luci-app-homeproxy_<版本>-all.apk
  ```
安装后首次启动服务时，插件会按设备架构自动下载并安装 reF1nd sing-box 内核；也可以在 LuCI 状态页「sing-box 内核管理」中手动点击「下载 / 更新内核」。

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

- `build-deploy.yml`（Build & Release All-in-One）：手动触发，输入版本号（如 `0.1.01`）后，云端编译打补丁的 reF1nd 内核（amd64/arm64/armv7/mipsle）+ luci 包（24.10 IPK 与 25.12 APK）。只发**一个** Release，标签即该版本号，包含：每架构一个一体化 zip（luci 包 + 内核 + install.sh）、独立可装的 `luci-app-homeproxy_<版本>-all.ipk` / `.apk`、以及 `sing-box-1.14.3-reF1nd-linux-*-musl.tar.gz`（供「更新内核」自动下载）。构建时会把 `update_core.sh` 的 `REFIND_TAG` 改写为该 Release 标签，因此装 IPK/APK 后也能自动从同一 Release 拉到打补丁内核。
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
