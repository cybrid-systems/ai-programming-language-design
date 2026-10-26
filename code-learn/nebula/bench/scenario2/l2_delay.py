#!/usr/bin/env python3
"""Userspace L2 forwarder used when the kernel has no sch_netem.

This VM's kernel is built with CONFIG_NET_SCH_NETEM unset, so
`tc qdisc add ... netem` returns "Specified qdisc kind is unknown".
The forwarder sits on the host side of each namespace veth and on one
uplink veth into br-nebula. Frames between namespace ports wait
--delay-ms before they are sent. Frames to or from the uplink (the
benchmark client on the host) are not delayed.

Ping from one namespace to another therefore sees about 2 * delay.
The script records nothing by itself; start_dist.sh ping is the RTT source.
"""

import argparse
import ctypes
import heapq
import os
import select
import socket
import struct
import threading
import time

ETH_P_ALL = 0x0003
PACKET_OUTGOING = 4
SIOCGIFFLAGS = 0x8913
SIOCSIFFLAGS = 0x8914
IFF_UP = 0x1
IFF_PROMISC = 0x100


def disable_offload(name):
    """AF_PACKET copies frames with checksum offload still incomplete.

    veth TX checksum / GSO leaves a partial checksum. The kernel bridge
    fixes that; a userspace copy does not, and TCP then times out while
    ICMP still works. Turn the offloads off on the ports we forward.
    """
    import fcntl

    ethtool = 0x8946
    cmds = (0x15, 0x17, 0x19, 0x1F, 0x24, 0x2C)  # rx, tx, sg, tso, gso, gro

    class EthtoolValue(ctypes.Structure):
        _fields_ = [("cmd", ctypes.c_uint32), ("data", ctypes.c_uint32)]

    class Ifreq(ctypes.Structure):
        _fields_ = [("ifr_name", ctypes.c_char * 16), ("ifr_data", ctypes.c_void_p)]

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, 0)
    try:
        for cmd in cmds:
            ev = EthtoolValue(cmd, 0)
            ifr = Ifreq()
            ifr.ifr_name = name.encode()[:15]
            ifr.ifr_data = ctypes.addressof(ev)
            try:
                fcntl.ioctl(sock, ethtool, ifr)
            except OSError:
                pass
    finally:
        sock.close()


def set_promisc(name):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, 0)
    try:
        ifr = struct.pack("16sH14s", name.encode()[:15], 0, b"")
        raw = fcntl_ioctl(sock, SIOCGIFFLAGS, ifr)
        flags = struct.unpack("16sH", raw[:18])[1]
        flags |= IFF_UP | IFF_PROMISC
        ifr = struct.pack("16sH14s", name.encode()[:15], flags, b"\x00" * 14)
        fcntl_ioctl(sock, SIOCSIFFLAGS, ifr)
    finally:
        sock.close()


def fcntl_ioctl(sock, req, buf):
    import fcntl

    return fcntl.ioctl(sock, req, buf)


class Port:
    def __init__(self, name, host_uplink):
        self.name = name
        self.host_uplink = host_uplink
        disable_offload(name)
        set_promisc(name)
        self.sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P_ALL))
        self.sock.bind((name, 0))
        self.sock.setblocking(False)


def mac_of(frame):
    dst = frame[0:6]
    src = frame[6:12]
    return dst, src


def is_broadcast(dst):
    return dst == b"\xff" * 6 or dst[0] & 0x01


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--delay-ms", type=float, required=True)
    parser.add_argument("--uplink", required=True, help="host-side veth toward br-nebula; not delayed")
    parser.add_argument("--ports", required=True, help="comma-separated host veths of the namespaces")
    args = parser.parse_args()
    delay_s = args.delay_ms / 1000.0
    names = [n.strip() for n in args.ports.split(",") if n.strip()]
    ports = [Port(args.uplink, True)] + [Port(name, False) for name in names]
    by_sock = {p.sock: p for p in ports}
    mac_table = {}
    lock = threading.Lock()
    queue = []  # (due, seq, out_sock, frame)
    seq = 0
    wakeup, wake_w = os.pipe()

    def enqueue(out, frame, wait):
        nonlocal seq
        due = time.monotonic() + wait
        with lock:
            seq += 1
            heapq.heappush(queue, (due, seq, out, frame))
        try:
            os.write(wake_w, b"x")
        except BlockingIOError:
            pass

    def sender():
        while True:
            with lock:
                item = queue[0] if queue else None
            if item is None:
                select.select([wakeup], [], [], 0.05)
                try:
                    os.read(wakeup, 64)
                except BlockingIOError:
                    pass
                continue
            due = item[0]
            now = time.monotonic()
            if due > now:
                gap = due - now
                if gap > 0.002:
                    select.select([wakeup], [], [], gap - 0.0005)
                    try:
                        os.read(wakeup, 64)
                    except BlockingIOError:
                        pass
                    continue
                while time.monotonic() < due:
                    pass
            with lock:
                if not queue or queue[0][1] != item[1]:
                    continue
                _, _, out, frame = heapq.heappop(queue)
            try:
                out.send(frame)
            except OSError:
                pass

    os.set_blocking(wakeup, False)
    os.set_blocking(wake_w, False)
    threading.Thread(target=sender, daemon=True).start()

    poll = select.poll()
    for port in ports:
        poll.register(port.sock, select.POLLIN)

    print(
        f"l2_delay delay_ms={args.delay_ms} uplink={args.uplink} ports={len(names)}",
        flush=True,
    )
    while True:
        events = poll.poll(500)
        for fd, _mask in events:
            port = None
            for candidate in ports:
                if candidate.sock.fileno() == fd:
                    port = candidate
                    break
            if port is None:
                continue
            try:
                frame, addr = port.sock.recvfrom(65535)
            except BlockingIOError:
                continue
            if len(frame) < 14 or len(addr) < 3 or addr[2] == PACKET_OUTGOING:
                continue
            dst, src = mac_of(frame)
            with lock:
                mac_table[src] = port
            targets = []
            if is_broadcast(dst):
                targets = [p for p in ports if p is not port]
            else:
                with lock:
                    owner = mac_table.get(dst)
                if owner is None or owner is port:
                    targets = [p for p in ports if p is not port]
                else:
                    targets = [owner]
            for target in targets:
                # One-way delay only on namespace-to-namespace frames.
                # Host uplink stays immediate so the client path is not the RTT.
                wait = 0.0 if (port.host_uplink or target.host_uplink) else delay_s
                enqueue(target.sock, frame, wait)


if __name__ == "__main__":
    main()
