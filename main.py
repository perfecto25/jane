import platform
import psutil
import msgpack
import socket
import json
import distro
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor
from loguru import logger
import argparse
import textwrap

from jane import get_system_info, create_msgpack_payload
from jane.cpu import get_cpu_info
from jane.disk import get_disk_usage

parser = argparse.ArgumentParser(
    formatter_class=argparse.RawDescriptionHelpFormatter,
    description=textwrap.dedent(
        """
    Jane monitoring agent
    """
    ),
)
parser.add_argument("-s", "--status", help="get status")


def main():
    system_data = get_system_info()
    logger.info(system_data)
   # print(json.dumps(system_data))
    payload = create_msgpack_payload(system_data)
    if payload:
        # Optionally save payload
        with open("system_info.msgpack", "wb") as f:
            f.write(payload)
     #   print("MessagePack payload saved to 'system_info.msgpack'")
        # Skip display to save time; uncomment below for debugging
        
        data = msgpack.unpackb(payload, raw=False)
        print(f"OS: {data['os']['name']} {data['os']['release']}")
        print(f"Memory: {data['memory']['total_bytes'] / (1024**3):.2f} GB")
        print(f"CPUs: {data['cpu']['count']}, {data['cpu']['brand']}")
        print(f"Mounts: {len(data['mounts'])} detected")
        


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"Error: {e}")
