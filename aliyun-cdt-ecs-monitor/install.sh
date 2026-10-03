#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/aliyun-cdt-ecs-monitor"
VENV_DIR="${APP_DIR}/venv"
PY_FILE="${APP_DIR}/monitor.py"
ENV_FILE="/root/.aliyun-cdt-ecs-monitor.env"
WRAPPER="/usr/local/sbin/aliyun-cdt-ecs-monitor"
LOG_FILE="/var/log/aliyun-cdt-ecs-monitor.log"

REGION_ID="cn-hongkong"
TRAFFIC_THRESHOLD_GB="180"
MONITOR_URL="https://raw.githubusercontent.com/vlongx/traffic_monitor/main/aliyun-cdt-ecs-monitor/monitor.py"

if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 用户运行。"
    exit 1
fi

clear

echo "============================================================"
echo "       Aliyun CDT ECS Traffic Monitor 安装程序"
echo "============================================================"
echo
echo "阿里云 CDT 流量监控与 ECS 自动启停工具"
echo

read -r -p "请输入 ECS 实例 ID（例如 i-xxxxxxxx）: " ECS_INSTANCE_ID
ECS_INSTANCE_ID="$(echo "${ECS_INSTANCE_ID}" | xargs)"

if [ -z "${ECS_INSTANCE_ID}" ]; then
    echo "错误：ECS 实例 ID 不能为空。"
    exit 1
fi

if [[ ! "${ECS_INSTANCE_ID}" =~ ^i-[A-Za-z0-9]+$ ]]; then
    echo "错误：ECS 实例 ID 格式似乎不正确。"
    exit 1
fi

echo
read -r -p "请输入 AccessKey ID: " ACCESS_KEY_ID
ACCESS_KEY_ID="$(echo "${ACCESS_KEY_ID}" | xargs)"

if [ -z "${ACCESS_KEY_ID}" ]; then
    echo "错误：AccessKey ID 不能为空。"
    exit 1
fi

echo
read -r -s -p "请输入 AccessKey Secret: " ACCESS_KEY_SECRET
echo

if [ -z "${ACCESS_KEY_SECRET}" ]; then
    echo "错误：AccessKey Secret 不能为空。"
    exit 1
fi

echo
echo "============================================================"
echo "当前配置"
echo "============================================================"
echo "区域：      ${REGION_ID}"
echo "ECS实例：   ${ECS_INSTANCE_ID}"
echo "流量阈值：  ${TRAFFIC_THRESHOLD_GB} GB"
echo "AccessKey： ${ACCESS_KEY_ID:0:6}********"
echo "============================================================"
echo

echo "[1/7] 安装系统依赖..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y python3 python3-pip python3-venv cron util-linux ca-certificates curl
systemctl enable --now cron

echo "[2/7] 创建程序目录..."
mkdir -p "${APP_DIR}"
chmod 700 "${APP_DIR}"

echo "[3/7] 下载监控程序..."
curl -fsSL "${MONITOR_URL}" -o "${PY_FILE}"
chmod 700 "${PY_FILE}"

echo "[4/7] 创建 Python 环境..."
if [ ! -x "${VENV_DIR}/bin/python" ]; then
    python3 -m venv "${VENV_DIR}"
fi

"${VENV_DIR}/bin/pip" install --upgrade pip
"${VENV_DIR}/bin/pip" install aliyun-python-sdk-core aliyun-python-sdk-ecs

echo "[5/7] 保存配置..."
umask 077
{
    printf 'ALIBABA_CLOUD_ACCESS_KEY_ID=%q\n' "${ACCESS_KEY_ID}"
    printf 'ALIBABA_CLOUD_ACCESS_KEY_SECRET=%q\n' "${ACCESS_KEY_SECRET}"
    printf 'ALIYUN_REGION_ID=%q\n' "${REGION_ID}"
    printf 'ALIYUN_ECS_INSTANCE_ID=%q\n' "${ECS_INSTANCE_ID}"
    printf 'TRAFFIC_THRESHOLD_GB=%q\n' "${TRAFFIC_THRESHOLD_GB}"
} > "${ENV_FILE}"

chmod 600 "${ENV_FILE}"

unset ACCESS_KEY_ID
unset ACCESS_KEY_SECRET

cat > "${WRAPPER}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/root/.aliyun-cdt-ecs-monitor.env"
PYTHON="/opt/aliyun-cdt-ecs-monitor/venv/bin/python"
SCRIPT="/opt/aliyun-cdt-ecs-monitor/monitor.py"

if [ ! -f "${ENV_FILE}" ]; then
    echo "配置文件不存在: ${ENV_FILE}"
    exit 1
fi

set -a
source "${ENV_FILE}"
set +a

exec /usr/bin/flock -n /run/aliyun-cdt-ecs-monitor.lock     /usr/bin/timeout 120s     "${PYTHON}" "${SCRIPT}" "$@"
SH

chmod 700 "${WRAPPER}"
touch "${LOG_FILE}"
chmod 600 "${LOG_FILE}"

echo "[6/7] 测试 AccessKey、CDT 和 ECS API..."
if ! "${WRAPPER}" --check-only; then
    echo
    echo "测试失败，不创建定时任务。"
    echo "请检查 AccessKey、RAM 权限、实例 ID 和区域。"
    exit 1
fi

echo "[7/7] 创建每 5 分钟运行一次的定时任务..."
TMP_CRON="$(mktemp)"
crontab -l 2>/dev/null | grep -v "aliyun-cdt-ecs-monitor" > "${TMP_CRON}" || true
echo "*/5 * * * * ${WRAPPER} >> ${LOG_FILE} 2>&1 # aliyun-cdt-ecs-monitor" >> "${TMP_CRON}"
crontab "${TMP_CRON}"
rm -f "${TMP_CRON}"

cat >/etc/logrotate.d/aliyun-cdt-ecs-monitor <<'ROTATE'
/var/log/aliyun-cdt-ecs-monitor.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    copytruncate
    create 0600 root root
}
ROTATE

echo
echo "============================================================"
echo "安装成功"
echo "============================================================"
echo
echo "每 5 分钟自动检查一次 CDT 流量。"
echo
echo "策略："
echo "  CDT < ${TRAFFIC_THRESHOLD_GB} GB  -> ECS 保持/恢复运行"
echo "  CDT >= ${TRAFFIC_THRESHOLD_GB} GB -> ECS 自动停止"
echo
echo "查看任务： crontab -l"
echo "只检查：   aliyun-cdt-ecs-monitor --check-only"
echo "手动执行： aliyun-cdt-ecs-monitor"
echo "查看日志： tail -f ${LOG_FILE}"
echo
