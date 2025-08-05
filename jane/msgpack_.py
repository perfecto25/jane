import msgpack

def create_msgpack_payload(system_data):
    try:
        return msgpack.packb(system_data, use_bin_type=True, strict_types=True)
    except Exception as e:
        print(f"Error creating MessagePack payload: {e}")
        return None
