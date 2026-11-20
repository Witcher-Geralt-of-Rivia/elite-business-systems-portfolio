"""Stop command for the ERP Redis services (WinSW <stopexecutable>): AUTH + SHUTDOWN over RESP.

Why: the service wrapper's Ctrl+C does not reach the MSYS2 Redis build, so it would be killed at the stop timeout.
SHUTDOWN makes Redis fsync the AOF / save the RDB per its config and exit cleanly. The port and password are read
from redis.conf in the working directory (the instance directory), so the password never appears on a command line.
The outcome is appended to stop.log in the same directory. Exit 0 when Redis accepted the shutdown.
"""
import re
import socket
import sys
import time


def resp(*parts: str) -> bytes:
	out = [b"*%d\r\n" % len(parts)]
	for p in parts:
		b = p.encode()
		out.append(b"$%d\r\n%s\r\n" % (len(b), b))
	return b"".join(out)


def main() -> int:
	conf = open("redis.conf", encoding="utf-8").read()
	port = int(re.search(r"^port\s+(\d+)", conf, re.M).group(1))
	pw = re.search(r"^requirepass\s+(\S+)", conf, re.M)
	with socket.create_connection(("127.0.0.1", port), timeout=15) as s:
		if pw:
			s.sendall(resp("AUTH", pw.group(1)))
			if not s.recv(64).startswith(b"+OK"):
				return log(port, "AUTH refused", 2)
		s.sendall(resp("SHUTDOWN"))
		try:
			reply = s.recv(256)  # the server closes the connection when it exits
		except OSError:
			reply = b""
	if reply.startswith(b"-"):
		return log(port, f"SHUTDOWN refused: {reply.decode(errors='replace').strip()}", 3)
	return log(port, "SHUTDOWN sent", 0)


def log(port: int, msg: str, code: int) -> int:
	with open("stop.log", "a", encoding="utf-8") as f:
		f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} port {port}: {msg}\n")
	return code


if __name__ == "__main__":
	import os

	if len(sys.argv) > 1:
		os.chdir(sys.argv[1])  # the instance directory (holds redis.conf); default: working directory
	try:
		sys.exit(main())
	except Exception as e:  # noqa: BLE001 - recorded for the operator
		sys.exit(log(0, f"error: {e!r}", 1))
