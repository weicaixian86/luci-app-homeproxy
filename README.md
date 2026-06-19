# luci-app-homeproxy
适用于 OpenWrt 24.10 的 HomeProxy LuCI 管理界面，已按 `sing-box 1.13.13` 配置结构进行适配。

## 安装说明
上传 zip 到 OpenWrt /tmp后解压并执行：

```sh
cd /tmp
unzip homeproxy-v2.0.1-x86_64.zip
cd homeproxy-v2.0.1-x86_64
sh install.sh
```

## 维护工作流
- `Rescan-Translation.yml`：代码变更后自动重新扫描并更新翻译文件，也支持手动运行。
- `Update-Geodata.yml`：每周自动更新内置 geodata 资源，也支持手动运行。

## 适配版本
- OpenWrt：24.10
- 架构：x86_64
- sing-box：1.13.13
