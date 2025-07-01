#!venv/bin/python

import platform
import psutil
import msgpack
import socket
import json
import sys

from loguru import logger
import argparse
import textwrap
from rio_config import Rio

from jane import get_system_info, create_msgpack_payload, gen_status_table

rio = Rio()
result = rio.parse_file("config.rio")


parser = argparse.ArgumentParser(
    formatter_class=argparse.RawDescriptionHelpFormatter,
    description=textwrap.dedent(
        """
    Jane monitoring agent
    """
    ),
)
parser.add_argument("-s", "--status", action="store_true", help="get Jane status")
parser.add_argument("-d", "--daemon", action="store_true", help="start Jane as daemon")
parser.add_argument("-c", "--config", help="path to config file")


def start():


    args = parser.parse_args()
    if args.status:
        logger.debug("getting Jane status")
        
        system_info = get_system_info()

        # generate status table
       # gen_status_table()
        print(json.dumps(result))

#        print(json.dumps(system_info))
        sys.exit()


    if args.daemon:
        system_info = get_system_info()
        payload = create_msgpack_payload(system_info)
        if payload:
            # Optionally save payload
            with open("system_info.msgpack", "wb") as f:
                f.write(payload)
        #   print("MessagePack payload saved to 'system_info.msgpack'")
            # Skip display to save time; uncomment below for debugging
            
            data = msgpack.unpackb(payload, raw=False)
            print(f"OS: {data['os']['name']} {data['os']['release']}")
            print(f"Memory: {data['memory']['total_bytes'] / (1024**3):.2f} GB")
            #print(f"CPUs: {data['cpu']['count']}, {data['cpu']['brand']}")
            print(f"Mounts: {len(data['mounts'])} detected")
        


if __name__ == "__main__":

    try:
        start()
    except Exception as e:
        print(f"Error: {e}")
