# -*- coding: utf-8 -*-

import argparse
import json
import logging
import os
import sys

from aliyunsdkcore.client import AcsClient
from aliyunsdkcore.request import CommonRequest
from aliyunsdkecs.request.v20140526.DescribeInstancesRequest import DescribeInstancesRequest
from aliyunsdkecs.request.v20140526.StartInstanceRequest import StartInstanceRequest
from aliyunsdkecs.request.v20140526.StopInstanceRequest import StopInstanceRequest

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
    stream=sys.stdout,
)

logger = logging.getLogger(__name__)

ACCESS_KEY_ID = os.environ.get("ALIBABA_CLOUD_ACCESS_KEY_ID")
ACCESS_KEY_SECRET = os.environ.get("ALIBABA_CLOUD_ACCESS_KEY_SECRET")
REGION_ID = os.environ.get("ALIYUN_REGION_ID", "cn-hongkong")
ECS_INSTANCE_ID = os.environ.get("ALIYUN_ECS_INSTANCE_ID")
TRAFFIC_THRESHOLD_GB = float(os.environ.get("TRAFFIC_THRESHOLD_GB", "180"))


def validate_config():
    missing = []
    if not ACCESS_KEY_ID:
        missing.append("ALIBABA_CLOUD_ACCESS_KEY_ID")
    if not ACCESS_KEY_SECRET:
        missing.append("ALIBABA_CLOUD_ACCESS_KEY_SECRET")
    if not ECS_INSTANCE_ID:
        missing.append("ALIYUN_ECS_INSTANCE_ID")
    if missing:
        raise RuntimeError("缺少配置: " + ", ".join(missing))


def create_client():
    return AcsClient(ACCESS_KEY_ID, ACCESS_KEY_SECRET, REGION_ID)


def get_total_traffic_gb(client):
    request = CommonRequest()
    request.set_domain("cdt.aliyuncs.com")
    request.set_version("2021-08-13")
    request.set_action_name("ListCdtInternetTraffic")
    request.set_method("POST")
    request.set_protocol_type("HTTPS")

    response = client.do_action_with_exception(request)
    data = json.loads(response.decode("utf-8"))

    traffic_details = data.get("TrafficDetails")
    if traffic_details is None:
        raise RuntimeError(
            "CDT API 返回中不存在 TrafficDetails。返回内容: "
            + json.dumps(data, ensure_ascii=False)
        )
    if not isinstance(traffic_details, list):
        raise RuntimeError(
            "TrafficDetails 返回格式异常。返回内容: "
            + json.dumps(data, ensure_ascii=False)
        )

    total_bytes = 0.0
    for item in traffic_details:
        if not isinstance(item, dict):
            continue
        try:
            total_bytes += float(item.get("Traffic", 0))
        except (TypeError, ValueError):
            logger.warning("无法解析 Traffic 字段: %r", item.get("Traffic"))

    total_gb = total_bytes / (1024 ** 3)
    logger.info("CDT 当前累计互联网流量: %.2f GB", total_gb)
    logger.info("流量阈值: %.2f GB", TRAFFIC_THRESHOLD_GB)
    return total_gb


def get_ecs_status(client, instance_id):
    request = DescribeInstancesRequest()
    request.set_InstanceIds(json.dumps([instance_id]))
    request.set_accept_format("json")

    response = client.do_action_with_exception(request)
    data = json.loads(response.decode("utf-8"))
    instances = data.get("Instances", {}).get("Instance", [])

    if not instances:
        raise RuntimeError(f"没有找到 ECS 实例: {instance_id}")

    status = instances[0].get("Status")
    logger.info("ECS %s 当前状态: %s", instance_id, status)
    return status


def start_ecs(client, instance_id):
    status = get_ecs_status(client, instance_id)

    if status == "Running":
        logger.info("ECS 已经运行，无需启动。")
        return

    if status in ("Starting", "Stopping"):
        logger.warning("ECS 当前状态为 %s，本次不执行启动。", status)
        return

    if status != "Stopped":
        logger.warning("ECS 当前状态为 %s，不是 Stopped，本次不执行启动。", status)
        return

    request = StartInstanceRequest()
    request.set_InstanceId(instance_id)
    request.set_accept_format("json")
    client.do_action_with_exception(request)
    logger.info("ECS 启动请求已经提交。")


def stop_ecs(client, instance_id):
    status = get_ecs_status(client, instance_id)

    if status == "Stopped":
        logger.info("ECS 已经停止，无需重复停止。")
        return

    if status in ("Starting", "Stopping"):
        logger.warning("ECS 当前状态为 %s，本次不执行停止。", status)
        return

    if status != "Running":
        logger.warning("ECS 当前状态为 %s，不是 Running，本次不执行停止。", status)
        return

    request = StopInstanceRequest()
    request.set_InstanceId(instance_id)
    request.set_ForceStop(False)
    request.set_accept_format("json")
    client.do_action_with_exception(request)
    logger.warning("ECS 停止请求已经提交。")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="只检查流量和实例状态，不执行开关机",
    )
    args = parser.parse_args()

    validate_config()
    client = create_client()

    logger.info("========================================")
    logger.info("开始检查阿里云 CDT 流量")
    logger.info("区域: %s", REGION_ID)
    logger.info("实例: %s", ECS_INSTANCE_ID)

    total_gb = get_total_traffic_gb(client)
    status = get_ecs_status(client, ECS_INSTANCE_ID)

    if args.check_only:
        logger.info("测试模式：仅检查，不执行开关机。")
        logger.info(
            "CDT流量 %.2f GB / 阈值 %.2f GB / ECS状态 %s",
            total_gb,
            TRAFFIC_THRESHOLD_GB,
            status,
        )
        return

    if total_gb >= TRAFFIC_THRESHOLD_GB:
        logger.warning(
            "流量 %.2f GB >= %.2f GB，触发保护。",
            total_gb,
            TRAFFIC_THRESHOLD_GB,
        )
        stop_ecs(client, ECS_INSTANCE_ID)
    else:
        logger.info(
            "流量 %.2f GB < %.2f GB，未达到保护阈值。",
            total_gb,
            TRAFFIC_THRESHOLD_GB,
        )
        start_ecs(client, ECS_INSTANCE_ID)

    logger.info("检查完成。")
    logger.info("========================================")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        logger.warning("程序被手动终止。")
        sys.exit(130)
    except Exception as exc:
        logger.exception("执行失败: %s", exc)
        sys.exit(1)
