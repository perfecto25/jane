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
    load_avg: list
    
    def cpu_info(self):
        return get_cpu_info()
    