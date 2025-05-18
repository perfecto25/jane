import platform
import psutil
import msgpack
import socket
import json
import distro
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor


from jane.cpu import get_cpu_info
from jane.disk import get_disk_usage




def get_system_info():
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

    system_info = {
        "timestamp": datetime.now().isoformat(),
        "hostname": socket.gethostname(),
        "os": {
            "name": platform.system(),
            "release": platform.release(),
            "distro": distro.name(pretty=True)
        },
        "memory": {
            "total_bytes": psutil.virtual_memory().total,
            "available_bytes": psutil.virtual_memory().available,
            "swap_total_bytes": swap.total,
            "swap_used_bytes": swap.used,
            "swap_free_bytes": swap.free
        },
        "cpu": get_cpu_info(),
        "load_avg": load_avg_dict
    }

    # Parallelize disk usage collection
    mounts = []
    partitions = psutil.disk_partitions()
    with ThreadPoolExecutor() as executor:
        results = executor.map(get_disk_usage, partitions)
        mounts = [r for r in results if r is not None]

    system_info["mounts"] = mounts
    return system_info


def create_msgpack_payload(system_data):
    try:
        return msgpack.packb(system_data, use_bin_type=True, strict_types=True)
    except Exception as e:
        print(f"Error creating MessagePack payload: {e}")
        return None


def main():
    system_data = get_system_info()
    print(json.dumps(system_data))
    payload = create_msgpack_payload(system_data)
    if payload:
        # Optionally save payload
        with open("system_info.msgpack", "wb") as f:
            f.write(payload)
     #   print("MessagePack payload saved to 'system_info.msgpack'")
        # Skip display to save time; uncomment below for debugging
        
        data = msgpack.unpackb(payload, raw=False)
        print(f"OS: {data['os']['name']} {data['os']['release']}")
        print(f"Memory: {data['memory']['total_bytes'] / (1024**3):.2f} GB")
        print(f"CPUs: {data['cpu']['count']}, {data['cpu']['brand']}")
        print(f"Mounts: {len(data['mounts'])} detected")
        


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"Error: {e}")
