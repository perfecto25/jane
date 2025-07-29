
import platform
import psutil
import msgpack
import socket
import sys
import json
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import distro
from loguru import logger
from collections import defaultdict

from rich import box
from rich.console import Console
from rich.table import Table
from dictor import dictor 
from .cpu import get_cpu_info, CPU
from .disk import get_disk_usage

def get_snapshot():
    """ memory and swap information """
    swap = psutil.swap_memory()

    try:
        load_avg = psutil.getloadavg()  # Returns tuple (1min, 5min, 15min)
        load_avg_dict = {
            "1min": load_avg[0],
            "5min": load_avg[1],
            "15min": load_avg[2]
        }
    except (AttributeError, OSError):
        # Fallback for Windows or systems without load average
        load_avg_dict = {
            "1min": None,
            "5min": None,
            "15min": None
        }
    
    cpu = get_cpu_info()
    
    # Parallelize disk usage collection
    mounts = []
    partitions = psutil.disk_partitions()
    with ThreadPoolExecutor() as executor:
        results = executor.map(get_disk_usage, partitions)
        mounts = [r for r in results if r is not None]

    system_info = {
        "summary": {
            "hostname": socket.gethostname(),
            "os": f"{platform.system()}, {platform.release()}, {platform.freedesktop_os_release().get('PRETTY_NAME', 'Uknown Linux Distribution')}",
            "memory": f"{psutil.virtual_memory().total / (1024**3):.2f} GB",
            "cpu": cpu,
           # "cpu": f"{cpu['count']} , {cpu['brand']}",
            "mounts": len(mounts)
        },
        "timestamp": datetime.now().isoformat(),
        "os": {
            "name": platform.system(),
            "release": platform.release(),
            "distro": distro.name(pretty=False)
        },
        "memory": {
            "total_bytes": psutil.virtual_memory().total,
            "available_bytes": psutil.virtual_memory().available,
            "swap_total_bytes": swap.total,
            "swap_used_bytes": swap.used,
            "swap_free_bytes": swap.free
        },
        "cpu": {
            "load_avg": load_avg_dict,
            "info": cpu,
        },
        "mounts": mounts
    }

    return system_info


def create_msgpack_payload(system_data):
    try:
        return msgpack.packb(system_data, use_bin_type=True, strict_types=True)
    except Exception as e:
        print(f"Error creating MessagePack payload: {e}")
        return None

def show_info(info, args):
    """ output basic host information """
    hostname = dictor(info, "summary.hostname")
    os_ver = dictor(info, "summary.os")
    cpu = f"""arch: {dictor(info, 'summary.cpu.arch')}\n\
    count: {dictor(info, 'summary.cpu.count')}\n\
    {dictor(info, 'summary.cpu.vendor_id_raw')} {dictor(info, 'summary.cpu.brand_raw')}\n\
        """
    if args.output in ["json", "jsonpretty"]:
        d = {}
        d["hostname"] = hostname
        d["OS version"] = os_ver
        d["cpu"] = {}
        d["cpu"]["arch"] = dictor(info, "summary.cpu.arch")
        d["cpu"]["count"] = dictor(info, "summary.cpu.count")
        
        if args.output == "jsonpretty":
            return json.dumps(d, indent=4)
        else:
            return json.dumps(d)
        
    else:
        console = Console()
        # table = Table(title="Jane agent info", show_header=False, box=box.ROUNDED, show_lines=True)
    
        # table.add_row("Hostname", hostname)
        # table.add_row("OS version", os_ver)
        # table.add_row("CPU arch", dictor(info, "summary.cpu.arch"))
        # table.add_row("CPU count", dictor(info, "summary.cpu.count", rtype="str"))
        # table.add_row("CPU vendor", dictor(info, "summary.cpu.vendor_id_raw"))
        # table.add_row("CPU brand", dictor(info, "summary.cpu.brand_raw"))
        # console.print(table)
    


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