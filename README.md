# 📊 VPS Traffic Monitor & Telegram Notifier

一个轻量级的 Linux 流量监控脚本，支持双向/单向流量统计、账单日重置，并支持通过 Telegram 发送流量日报。

## 🚀 一键安装

```bash
curl -sL https://raw.githubusercontent.com/vlongx/traffic_monitor/main/traffic_monitor.sh -o traffic_monitor.sh && bash traffic_monitor.sh install
```
⚙️ Crontab 定时任务 (必填)
安装完成后，输入 crontab -e 添加以下内容，以防止重启丢失数据：
```bash
# 每 5 分钟更新数据 (防止重启丢数据)
*/5 * * * * bash /root/traffic_monitor.sh update > /dev/null 2>&1

# 每天 09:00 推送日报
0 9 * * * bash /root/traffic_monitor.sh report > /dev/null 2>&1
```

测试推送TG脚本：
```bash
bash traffic_monitor.sh report
```

