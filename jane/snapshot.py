import psutil
from datetime import datetime
import platform
import socket
import distro 
from loguru import logger
from concurrent.futures import ThreadPoolExecutor
from .cpu import CPU
from .disk import get_disk_usage


def get_snapshot():
    """ memory and swap information """
    swap = psutil.swap_memory()
    
    
    #cpu = get_cpu_info()
    
    # Parallelize disk usage collection
    mounts = []
    partitions = psutil.disk_partitions()
    with ThreadPoolExecutor() as executor:
        results = executor.map(get_disk_usage, partitions)
        mounts = [r for r in results if r is not None]

    ret = {}
    ret["hostname"] = socket.gethostname()
    ret["cpu"] = CPU.snapshot()
    ret["memory"] = {}
    ret["memory"]["total_b"] = psutil.virtual_memory().total
#    ret["memory"]["total_mb"] = f"{psutil.virtual_memory().total / (1024**2):.2f}"
#    ret["memory"]["total_gb"] = f"{psutil.virtual_memory().total / (1024**3):.2f}"
    ret["memory"]["avail_b"] = psutil.virtual_memory().available
    ret["memory"]["swap"] = {}
    ret["memory"]["swap"]["total_b"] = swap.total
    ret["memory"]["swap"]["used_b"]  = swap.used
    ret["memory"]["swap"]["avail_b"]  = swap.free
#    ret["memory"]["swap"]["avail_mb"]  = f"{swap.free / (1024**2):.2f}"
#    ret["memory"]["swap"]["avail_gb"]  = f"{swap.free / (1024**3):.2f}"
    ret["os"] = {}
    ret["os"]["system"] = platform.system()
    ret["os"]["release"] = platform.release()
    ret["os"]["distro"] = platform.freedesktop_os_release().get('PRETTY_NAME', 'Uknown Linux Distribution')
    
#    ret["mounts"] = mounts

    ret["timestamp"] = datetime.now().isoformat()
 
    return ret
