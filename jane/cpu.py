import psutil
import platform
import cpuinfo
from functools import lru_cache

@lru_cache(maxsize=1)
def get_cpu_info():
    """Cache CPU info to avoid repeated slow calls."""
    return cpuinfo.get_cpu_info()

    