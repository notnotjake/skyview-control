import ipaddress
import socket
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed


def check(ip: str, port: int, timeout: float) -> str | None:
    try:
        with socket.create_connection((ip, port), timeout=timeout):
            return ip
    except OSError:
        return None


def main() -> int:
    network = sys.argv[1] if len(sys.argv) > 1 else "192.168.4.0/22"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 6668
    timeout = float(sys.argv[3]) if len(sys.argv) > 3 else 0.35

    hosts = [str(ip) for ip in ipaddress.ip_network(network, strict=False).hosts()]
    found: list[str] = []

    with ThreadPoolExecutor(max_workers=128) as executor:
        futures = [executor.submit(check, ip, port, timeout) for ip in hosts]
        for future in as_completed(futures):
            result = future.result()
            if result:
                found.append(result)
                print(result, flush=True)

    return 0 if found else 1


if __name__ == "__main__":
    raise SystemExit(main())
