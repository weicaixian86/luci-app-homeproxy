# luci-app-homeproxy
适用于 OpenWrt 24.10 的 HomeProxy LuCI 管理界面，已按 `sing-box 1.13.13` 配置结构进行适配。

## 安装
上传 zip 到 OpenWrt /tmp目录后解压并执行（文件名homeproxy-2.0.1-x86_64.zip自行替换）：
```sh
cd /tmp
unzip homeproxy-2.0.1-x86_64.zip
cd homeproxy-2.0.1-x86_64
sh install.sh
```

## 卸载
```sh
/etc/init.d/homeproxy stop 2>/dev/null || true
opkg remove luci-app-homeproxy sing-box
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```

如果还想顺手清理配置文件：
```sh
rm -f /etc/config/homeproxy
rm -rf /etc/homeproxy
rm -rf /usr/share/homeproxy
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```
不建议直接批量卸载所有依赖包，因为像 curl、ca-bundle、firewall4、dnsmasq-full、ip-full、ucode-* 可能被系统或其他插件共用。

## 维护工作流
- `Rescan-Translation.yml`：代码变更后自动重新扫描并更新翻译文件，也支持手动运行。
- `Update-Geodata.yml`：每周自动更新内置 geodata 资源，也支持手动运行。

## 适配版本
- OpenWrt：24.10
- 架构：x86_64
- sing-box：1.13.13
