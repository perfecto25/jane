#!venv/bin/python

import platform
import psutil
import msgpack
import socket
import json
import sys
import os
from dictor import dictor 
from loguru import logger
import argparse
import textwrap
from rio_config import Rio

from jane import get_snapshot, compare_status, create_msgpack_payload, gen_status_table, Payload


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
parser.add_argument("-i", "--info", action="store_true", help="show basic host information")
parser.add_argument("-c", "--config", help="path to config file")
parser.add_argument(
    "-o",
    "--output",
    choices=["json", "jsonpretty"],
    required=False,
    help="Select output format: json, jsonpretty"
)
parser.add_argument("-v", "--verbose", help="verbose output")

def start():
    args = parser.parse_args()
    args_dict = vars(args)
    # parse jane config.rio file
    cfg_file = args.config or "/etc/jane/config.rio"

    payload = Payload(cfg_file, args_dict)

    if args.info:
        payload.show_info()
        sys.exit()

    if args.status:
        if not os.path.exists(cfg_file):
            print(f"Jane config not found in path {cfg_file}, exiting")
            sys.exit(1)
        rio = Rio() 
        cfg = rio.parse_file(cfg_file)
        logger.info(cfg)
        logger.debug("getting Jane status")
        
        snapshot = get_snapshot()
        payload = compare_status(snapshot, cfg)
        gen_status_table(payload)
#        print(json.dumps(result))

#        print(json.dumps(system_info))
        sys.exit()


    if args.daemon:
        snapshot = get_snapshot()
        payload = create_msgpack_payload(snapshot)
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
