import psutil

def get_disk_usage(mount):
    """Helper function for parallel disk usage collection."""
    try:
        usage = psutil.disk_usage(mount.mountpoint)
        return {
            "device": mount.device,
            "mountpoint": mount.mountpoint,
            "fstype": mount.fstype,
            "total_bytes": usage.total,
            "used_bytes": usage.used,
            "free_bytes": usage.free,
            "percent_used": usage.percent
        }
    except (PermissionError, OSError):
        return None