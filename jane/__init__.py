
import platform
import psutil
import msgpack
import socket
import sys
import json

from datetime import datetime
import distro
from loguru import logger
from collections import defaultdict
from dataclasses import dataclass
from rich import box
from rich.console import Console
from rich.table import Table
from dictor import dictor 
from .snapshot import get_snapshot
from .msgpack_  import create_msgpack_payload

def bytes_to_gb(b):
    kb = b / 1024
    mb = kb / 1024
    gb = mb / 1024
    return [kb, mb, gb]

@dataclass
class Payload:
    
    cfg: str
    args: dict

    def show_info(args):
        snapshot = get_snapshot()
        swap = dictor(snapshot, "memory.swap_total_bytes")

        if dictor(args, "output") and dictor(args, "output") in ["json", "jsonpretty"]:
            d = {}
            d["hostname"] = dictor(snapshot, "summary.hostname")
            d["OS version"] = dictor(snapshot, "summary.os")
            d["cpu"] = {}
            d["cpu"]["arch"] = dictor(snapshot, "summary.cpu.arch")
            d["cpu"]["count"] = dictor(snapshot, "summary.cpu.count")
            d["memory"] = dictor(snapshot, "summary.memory")
        
            if args.output == "jsonpretty":
                return json.dumps(d, indent=4)
            else:
                return json.dumps(d)        
        else:
            console = Console()
            table = Table(title="Jane agent info", show_header=False, box=box.ROUNDED, show_lines=True)
            table.add_row("Hostname", dictor(snapshot, "summary.hostname"))
            table.add_row("OS version", dictor(snapshot, "summary.os"))
            table.add_row("CPU arch", dictor(snapshot, "summary.cpu.arch"))
            table.add_row("CPU count", dictor(snapshot, "summary.cpu.count", rtype="str"))
            table.add_row("CPU vendor", dictor(snapshot, "summary.cpu.vendor_id_raw"))
            table.add_row("CPU brand", dictor(snapshot, "summary.cpu.brand_raw"))
            table.add_row("Memory", dictor(snapshot, "summary.memory") + f" swap: {bytes_to_gb(swap)[2]}")
            console.print(table)

def gen_status_table(payload):
    """ output a status table of system """
    console = Console()
    table = Table(title="status")

    table.add_column("check", style="cyan", no_wrap=True)
    table.add_column("status", style="magenta")
    table.add_column("output", style="green")

    if 'alert' in payload.keys():
        for section, data in payload['alert'].items():
            logger.debug(f'k={section}')
            logger.debug(f'v={data}')
            # for k,v in data.items():
            #     logger.warning(type(k))
            #     logger.warning(type(v))
            #     table.add_row(k, 'alert', v)
            

    for check, status in payload.items():
        logger.info(check)
        logger.info(status)
    table.add_row("Alice", "30", "New York")
    table.add_row("Bob", "24", "London")
    table.add_row("Charlie", "35", "Paris")

    console.print(table)

def compare_status(snapshot, cfg):
    """ compare actual snapshot vs rules defined in config file """
    print("comparing status of actual vs config file")
    #import json
    #logger.info(json.dumps(cfg, indent=4))
    def tree():
        return defaultdict(tree)

    def convert(d):
        if isinstance(d, defaultdict):
            d = {k: convert(v) for k, v in d.items()}
        return d
    
    ret = tree()
    ret['alert'] = tree()
    ret['ok'] = tree()

    if 'check' not in cfg.keys():
        raise Exception("COnfig file doesnt have 'check' section")

    for  check_type, check_data in cfg['check'].items():
        if check_type not in ["cpu", "memory"]:
            logger.warning(f"{check_type} is not a valid type of check")
            continue 

        # check cpu load avg
        if dictor(cfg['check'], 'cpu.load_avg'):            
            expected = dictor(cfg['check'], 'cpu.load_avg')
            actual = dictor(snapshot, 'cpu.load_avg')
            for key, val in expected.items():
                if dictor(snapshot, f'cpu.load_avg.{key}'):
                    if actual[key] > expected[key]:
                        ret['alert']['cpu']['load_avg'][key] = [expected[key], actual[key] ]
                    else:
                        ret['ok']['cpu']['load_avg'][key] = [expected[key], actual[key]]
    return convert(ret)
#  for key, val in snapshot.items():
#        logger.warning(f"{key} {val}")