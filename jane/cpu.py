import psutil
import platform
import cpuinfo
from functools import lru_cache
from dataclasses import dataclass


@lru_cache(maxsize=1)
def get_cpu_info():
    """Cache CPU info to avoid repeated slow calls."""
    
    return cpuinfo.get_cpu_info()

@dataclass
class CPU():
    def snapshot():
        cpu_info = get_cpu_info()
        ret = {}
        ret["load_avg"] = {}
        ret["load_avg"]["usage"] = list(psutil.getloadavg())
        ret["arch"] = cpu_info["arch"]
        ret["count"] = cpu_info["count"]
        ret["brand"] = cpu_info["brand_raw"]
        ret["vendor"] = cpu_info["vendor_id_raw"]
        return ret


    def cpu_info(self):
        return get_cpu_info()
    