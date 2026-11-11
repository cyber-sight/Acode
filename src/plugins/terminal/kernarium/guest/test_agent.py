#!/usr/bin/env python3
"""Host test for acode-vsock-pty: builds the agent with the host compiler,
runs it on loopback TCP and checks the session protocol end to end.

usage: python3 test_agent.py   (Linux; needs cc and libutil)
"""
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def frame(kind, payload=b""):
    return kind + struct.pack(">I", len(payload)) + payload


def open_session(port, command=b"", columns=80, rows=24):
    connection = socket.create_connection(("127.0.0.1", port), timeout=5)
    connection.sendall(frame(b"O", struct.pack(">HH", columns, rows) + command))
    return connection


def read_until(connection, marker=None, timeout=5.0):
    """Returns (output, exit status or None) once `marker` appears, the
    session exits, or the timeout passes."""
    connection.settimeout(0.2)
    buffer, output, deadline = b"", b"", time.time() + timeout
    while time.time() < deadline:
        try:
            data = connection.recv(65536)
        except socket.timeout:
            continue
        if not data:
            break
        buffer += data
        while len(buffer) >= 5:
            length = struct.unpack(">I", buffer[1:5])[0]
            if len(buffer) < 5 + length:
                break
            kind, payload, buffer = buffer[:1], buffer[5:5 + length], buffer[5 + length:]
            if kind == b"D":
                output += payload
            elif kind == b"X":
                return output, struct.unpack(">i", payload)[0]
        if marker is not None and marker in output:
            return output, None
    return output, None


def alive(pid):
    try:
        with open(f"/proc/{pid}/stat") as stat:
            return stat.read().split()[2] != "Z"
    except FileNotFoundError:
        return False


def main():
    with tempfile.TemporaryDirectory() as work:
        agent = os.path.join(work, "acode-vsock-pty")
        subprocess.run(
            ["cc", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-o", agent,
             os.path.join(HERE, "acode-vsock-pty.c"), "-lutil"],
            check=True)
        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
        probe.close()
        server = subprocess.Popen([agent, "-t", str(port)], stderr=subprocess.DEVNULL)
        try:
            time.sleep(0.3)
            run_checks(port, work)
        finally:
            server.terminate()
            server.wait(timeout=5)
    print("acode-vsock-pty: all checks passed")


def run_checks(port, work):
    # A one-shot command sees the requested size and reports its status.
    session = open_session(port, b"stty size; echo hi; exit 3", 100, 30)
    output, status = read_until(session)
    assert b"30 100" in output and b"hi" in output, output
    assert status == 3, status

    # An interactive shell follows a resize and runs typed input.
    session = open_session(port)
    session.sendall(frame(b"R", struct.pack(">HH", 132, 43)))
    time.sleep(0.3)
    session.sendall(frame(b"D", b"stty size; echo MARK$((1+1))\n"))
    output, _ = read_until(session, b"MARK2")
    assert b"43 132" in output and b"MARK2" in output, output

    # Ctrl-C interrupts the foreground job, not the shell. The markers are
    # computed so the echoed command line cannot match them.
    session.sendall(frame(b"D", b"sleep 30; echo AFTER$((5+5))\n"))
    time.sleep(0.5)
    session.sendall(frame(b"D", b"\x03"))
    session.sendall(frame(b"D", b"echo BACK$((2+2))\n"))
    output, _ = read_until(session, b"BACK4")
    assert b"BACK4" in output and b"AFTER10" not in output, output
    session.sendall(frame(b"D", b"exit 0\n"))
    _, status = read_until(session)
    assert status == 0, status

    # Closing the stream hangs up the session's processes.
    pid_file = os.path.join(work, "pid")
    session = open_session(port, f"echo $$ > {pid_file}; sleep 60".encode())
    time.sleep(0.5)
    session.close()
    time.sleep(0.5)
    with open(pid_file) as handle:
        pid = int(handle.read())
    assert not alive(pid), f"session process {pid} survived the hang-up"


if __name__ == "__main__":
    sys.exit(main())
