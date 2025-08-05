import psutil
from datetime import datetime
import platform
import socket
import distro 
from concurrent.futures import ThreadPoolExecutor
from .cpu import get_cpu_info, CPU
from .disk import get_disk_usage


def get_snapshot():
    """ memory and swap information """
    swap = psutil.swap_memory()
    print(CPU.snapshot())
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
