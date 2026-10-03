# Aliyun CDT ECS Traffic Monitor

阿里云 CDT 流量监控与 ECS 自动启停工具。

当 CDT 累计流量达到设定阈值后，自动停止指定 ECS；低于阈值时确保 ECS 处于运行状态。

## 功能

- 安装时交互输入 ECS Instance ID
- 安装时输入 AccessKey ID / Secret
- AccessKey Secret 输入时不回显
- 自动查询阿里云 CDT 流量
- 自动查询 ECS 状态
- CDT 低于阈值时保持 / 恢复 ECS 运行
- CDT 达到阈值时自动停止 ECS
- 默认每 5 分钟检查一次
- 配置文件权限自动设置为 600
- 使用 flock 防止定时任务重复执行
- 支持只读检查模式

## 默认配置

- Region: `cn-hongkong`
- 流量阈值: `180 GB`
- 检查周期: 每 5 分钟

## 一键安装

以 root 用户执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vlongx/traffic_monitor/main/aliyun-cdt-ecs-monitor/install.sh)
```

安装程序会依次要求输入：

1. ECS Instance ID
2. AccessKey ID
3. AccessKey Secret

安装完成后会自动测试 CDT 与 ECS API，测试成功后才创建定时任务。

## 常用命令

只查询，不执行开关机：

```bash
aliyun-cdt-ecs-monitor --check-only
```

手动执行完整逻辑：

```bash
aliyun-cdt-ecs-monitor
```

查看定时任务：

```bash
crontab -l
```

查看日志：

```bash
tail -f /var/log/aliyun-cdt-ecs-monitor.log
```

## 工作逻辑

```text
每 5 分钟
   ↓
查询阿里云 CDT 流量
   ↓
< 180 GB
   ↓
确保 ECS Running

>= 180 GB
   ↓
停止 ECS
```

## 注意

建议使用独立 RAM 用户的 AccessKey，并只授予 CDT 查询、ECS 查询、启动和停止实例所需的最小权限。

不要把 AccessKey 写入 GitHub 仓库。

定时任务应部署在不会被本脚本关闭的外部 VPS 上，否则目标 ECS 关机后将无法自行重新启动。
