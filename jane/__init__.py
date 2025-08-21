
import platform
import psutil

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
from .msg_pack  import create_msgpack

from rio_config import Rio 

VALID_CHECKS = ["cpu", "memory"]

def bytes_to_gb(b):
    kb = b / 1024
    mb = kb / 1024
    gb = mb / 1024
    return [kb, mb, gb]



@dataclass
class Payload:
    
    cfg_file: str
    args: dict

    def show_info(self):
        logger.info("A1")
        snapshot = get_snapshot()
        logger.info(type(snapshot))
        logger.info(json.dumps(snapshot, indent=4))

        if dictor(self.args, "output") and dictor(self.args, "output") in ["json", "jsonpretty"]:
            if self.args['output'] == "jsonpretty":
                print(json.dumps(snapshot, indent=4))
            else:
                print(json.dumps(snapshot))        
        else:
            console = Console()
            table = Table(title="Jane agent info", show_header=False, box=box.ROUNDED, show_lines=True)
            table.add_row("Hostname", dictor(snapshot, "hostname"))
            table.add_row("OS version", dictor(snapshot, "os.system"))
            table.add_row("CPU arch", dictor(snapshot, "cpu.arch"))
            table.add_row("CPU count", dictor(snapshot, "cpu.count", rtype="str"))
            table.add_row("CPU vendor", dictor(snapshot, "cpu.vendor"))
            table.add_row("CPU brand", dictor(snapshot, "cpu.brand"))
            table.add_row("Memory", f"{dictor(snapshot, "memory.total_b") / (1024**3):.2f} GB")
            if dictor(snapshot, "memory.swap.total_b") != 0:
                table.add_row("Swap", f"{dictor(snapshot, "memory.swap.total_b") / (1024**3):.2f} GB")
            
            console.print(table)
    
    def get_status(self):
        snapshot = get_snapshot()
        rio = Rio()
        cfg = rio.parse_file(self.cfg_file)
        status = compare_status(snapshot, cfg)
        return status


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
    

    logger.info(f"SNAPSHOT CPU {snapshot['cpu']}")

    logger.debug(f"CFG = {cfg}")
    #logger.info(json.dumps(cfg, indent=4))
    def tree():
        return defaultdict(tree)

    def convert(d):
        if isinstance(d, defaultdict):
            d = {k: convert(v) for k, v in d.items()}
        return d
    
    ret = tree()
    ret[1] = tree()
    ret[0] = tree()

    if 'check' not in cfg.keys():
        raise Exception("COnfig file doesnt have 'check' section")


    # def compare(lookup_key):        
    #     if dictor(cfg['check'], lookup_key):
    #         expected = dictor(cfg['check'], f'{lookup_key}')
    #         actual = dictor(snapshot, f'{lookup_key}')
    #         logger.debug(f"expected = {expected}")
    #         logger.debug(f"actual = {actual}")
    #   

    for  check_type, check_data in cfg['check'].items():
        logger.warning(check_type)
        logger.warning(check_data)

        if check_type not in VALID_CHECKS:
            logger.warning(f"{check_type} is not a valid type of check")
            continue

        expected = dictor(cfg["check"], f"{check_type}")
        actual = dictor(snapshot, f"{check_type}")
        for section, data in expected.items():
            if not dictor(data, "usage"):
                continue
            if type(data) is dict:
                logger.info("DICT")
                for key in data.keys():
#                    if type(dictor(expected, f"{section}.{key}")) is list:
                        

                    logger.warning(expected[section][key])
                    logger.error(dictor(actual, f"{section}.{key}", rtype="int"))
                    logger.error(dictor(expected, f"{section}.{key}", rtype="int"))

                    if dictor(actual, f"{section}.{key}", rtype="int") > dictor(expected, f"{section}.{key}", rtype="int"):
                        logger.error("ALERT")
                        status_code = 1
                        
                    else:
                        status_code = 0
                ret[status_code][check_type][section][key] = [expected[section][key], actual[section][key]]
                # logger.error(actual[k])
                # logger.error(expected[k])
                # if actual[k] > expected[k]:
                #     ret['alert']['cpu']['load_avg'][k] = [expected[k], actual[k] ]
                # else:
                #     ret['ok']['cpu' ]['load_avg'][k] = [expected[k], actual[k]]
    return convert(ret)
#  for key, val in snapshot.items():
#        logger.warning(f"{key} {val}")