适用于 OpenWrt 的 HomeProxy LuCI 管理界面。
HomeProxy 本身为架构无关的 LuCI 包（`LUCI_PKGARCH:=all`），**安装包内不预置任何单一架构的 sing-box 二进制**。运行时由插件根据设备架构，从本仓库的 Release（`weicaixian86/luci-app-homeproxy`，标签 `v1.14.3-reF1nd`）下载对应架构的打补丁内核压缩包（含 clash proxy-providers 补丁），校验后安装到 `/usr/bin/sing-box`。
当前固定使用 reF1nd 定制内核：
- 版本：`1.14.3-reF1nd`
- 发布地址：`https://github.com/weicaixian86/luci-app-homeproxy/releases/tag/v1.14.3-reF1nd`
reF1nd 目前已发布 Linux musl 构建的架构：
- `x86_64`（`linux-amd64-musl`）
- `aarch64`（`linux-arm64-musl`）
其余架构（armv7-musleabihf / armv7-musleabi / arm-musleabihf / arm-musleabi / mips / mipsel）reF1nd 暂未发布对应构建，插件会在日志中提示“暂无可下载的二进制程序”，作者后续可能会补充；已安装的内核（若有）仍可继续使用。

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

- `build.yml`：手动触发，输入 Release tag 与（可选的）描述后，编译 24.10 的 IPK 与 25.12 的 APK，并仅上传 `luci-app-homeproxy` 的 IPK 与 APK。
- `build-deploy.yml`（Build & Release All-in-One）：手动触发，输入版本号后，云端编译打补丁的 reF1nd 内核（amd64/arm64/armv7/mipsle）+ luci 包（24.10 IPK 与 25.12 APK）。产出全部发到 `deploy-<版本>` Release，包含：每架构一个一体化 zip（luci IPK + 内核 + install.sh）、独立可装的 `luci-app-homeproxy.ipk` / `.apk`；**同时**把 amd64/arm64 的内核压缩包发到 `v1.14.3-reF1nd` Release，供「更新内核」按钮自动下载打补丁内核。只跑这一个 workflow 即可覆盖所有安装方式。
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
