import psutil
import platform
from functools import lru_cache

@lru_cache(maxsize=1)
def get_cpu_info():
    """Cache CPU info to avoid repeated slow calls."""
    return {
        "count": psutil.cpu_count(logical=True),
        "brand": platform.processor() or "Unknown",
        "arch": platform.machine() or "Unknown"
    }