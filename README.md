# luci-app-homeproxy
适用于 OpenWrt 24.10 的 HomeProxy LuCI 管理界面，已按 `官方内核sing-box 1.13.13` 配置结构进行适配。

## 安装
上传 zip 到 OpenWrt /tmp目录后解压并执行（文件名homeproxy-2.0.1-x86_64.zip自行替换）：
```sh
cd /tmp
unzip homeproxy-2.0.1-x86_64.zip
cd homeproxy-2.0.1-x86_64
sh install.sh
```

## 安装新包后如果页面仍显示旧文字，建议清浏览器缓存，或执行：
```sh
rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache/*
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```

## 卸载
```sh
/etc/init.d/homeproxy stop 2>/dev/null || true
/etc/init.d/homeproxy disable 2>/dev/null || true
opkg remove luci-i18n-homeproxy-zh-cn 2>/dev/null || true
opkg remove luci-app-homeproxy 2>/dev/null || true
rm -rf /etc/config/homeproxy
rm -rf /etc/homeproxy
rm -rf /usr/share/homeproxy
rm -rf /www/luci-static/resources/view/homeproxy
rm -f /www/luci-static/resources/homeproxy.js
rm -f /usr/share/luci/menu.d/luci-app-homeproxy.json
rm -f /usr/share/rpcd/acl.d/luci-app-homeproxy.json
rm -f /usr/share/rpcd/ucode/luci.homeproxy
rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache/*
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```

## 维护工作流
- `Rescan-Translation.yml`：代码变更后自动重新扫描并更新翻译文件，也支持手动运行。
- `Update-Geodata.yml`：每周自动更新内置 geodata 资源，也支持手动运行。

## 面版下载失败解决办法
第一种：点击更新面版手动触发面版下载。  
第二种：下载面版ZIP包，手动上传面版ZIP。  
下载地址镜像  
```sh
https://gh-proxy.com/https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip
```
或者直连
```sh
https://gh-proxy.com/https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip
```

## 感谢作者
VIKINGYFY
https://github.com/VIKINGYFY/homeproxy

immortalwrt
https://github.com/immortalwrt/homeproxy