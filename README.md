# Xray VLESS 反向代理（多用户一对一落地）部署脚本

在中转 VPS 上交互式部署 Xray，实现**多用户一一对应的全量转发**：

- 外部用户 user1 / user2 / ... 通过 VLESS + REALITY 接入 VPS；
- 每个用户对应一台专属落地设备（手机 / 家宽），该设备主动回连 VPS 建立反向隧道；
- 用户 N 的全部流量经 `reverse-out-N` 送入专属隧道，由落地设备 N 从本地出口访问公网；
- 不需要分流，全部转发。

## 使用方法

```bash
sudo bash xray-reverse-setup.sh
```

交互输入：用户 email 列表（第 N 个用户对应第 N 台落地设备）、端口、REALITY 伪装目标、shortId 等；其余凭证（UUID、X25519 密钥对、VLESS Encryption 对）全部自动生成。

## 功能

- 自动安装 Xray（官方安装脚本 XTLS/Xray-install 或手动下载）
- 自动生成全部凭证，无需手工复制
- 写入配置前自动备份，写入后 `xray run -test` 校验，失败自动还原
- 为每个用户生成一份落地设备配置 `/root/xray-bridge-<email>.jsonc`
- 打印每个用户的 VLESS 分享链接
- 配置 systemd 服务并放行 ufw 端口

## 配置依据

配置字段仅使用 Xray-core 官方全量文档（[https://xtls.github.io/llms-full.txt](https://xtls.github.io/llms-full.txt)）确认过的字段、取值与限制。

## 注意事项

- 落地设备需保持在线：v2rayNG 自定义配置导入，连接时弹出的 VPN 请求选取消（仅代理模式）
- 云厂商安全组需放行用户接入端口与隧道端口（默认 443/tcp、8443/tcp）
