"""Native-Windows launcher for Frappe (spike). Applies narrowly scoped runtime adaptations, then runs Frappe's own
CLI entry point exactly as `bench` does (`python -m frappe.utils.bench_helper frappe ...`). No upstream file is
modified. Each adaptation names the Unix assumption it replaces.

Import-time shims (signal constants, os.register_at_fork, faulthandler.register) live in sitecustomize.py.
"""
import re
import runpy
import shutil
import subprocess
import sys

import frappe  # noqa: E402  (sitecustomize has made the import possible)
from frappe.database import db_manager

_SANDBOX = re.compile(r"^/\*M?!999999\\- enable the sandbox mode \*/\s*$")
_DEFINER = re.compile(r"/\*![0-9]* DEFINER=[^ ]* SQL SECURITY DEFINER \*/")


def restore_database(verbose, target, source, user, password):
	"""Replaces `cat src | sed .. | sed .. | mariadb ..` run through bash (frappe.utils.execute_in_shell): the same
	two filters in Python, the SQL streamed to mariadb.exe's stdin. Gzipped sources are decompressed in-process."""
	import gzip

	from frappe.database import get_command

	bin, args, bin_name = get_command(
		socket=frappe.conf.db_socket, host=frappe.conf.db_host, port=frappe.conf.db_port,
		user=user, password=password, db_name=target,
	)
	if not bin:
		frappe.throw(f"{bin_name} not found in PATH! This is required to restore the database.", exc=frappe.ExecutableNotFound)
	opener = gzip.open if source.endswith(".gz") else open
	p = subprocess.Popen([bin, *args], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
	with opener(source, "rt", encoding="utf-8") as f:
		for line in f:
			if frappe.conf.db_type == "mariadb":
				if _SANDBOX.match(line):
					continue
				line = _DEFINER.sub("", line)
			p.stdin.write(line.encode("utf-8"))
	p.stdin.close()
	out, err = p.stdout.read(), p.stderr.read()
	if p.wait() != 0:
		raise frappe.CommandFailedError("Command failed", out.decode(errors="replace"), err.decode(errors="replace"))
	frappe.cache.delete_keys("")


if sys.platform == "win32":
	db_manager.DbManager.restore_database = staticmethod(restore_database)

	# Frappe builds template names with os.path.join ("www\\error.html"); Jinja only accepts "/" and rejects a
	# name piece containing os.sep. Normalise before Jinja splits the name.
	import jinja2.loaders

	_split = jinja2.loaders.split_template_path
	jinja2.loaders.split_template_path = lambda template: _split(template.replace("\\", "/"))

	# frappe.commands.popen lowers the child's priority through preexec_fn (unsupported on Windows); the Windows
	# equivalent is a creation flag. Same arguments and return semantics otherwise.
	import os

	import frappe.commands

	def popen(command, *args, **kwargs):
		env = kwargs.get("env")
		proc = subprocess.Popen(
			command,
			stdout=None if kwargs.get("output", True) else subprocess.PIPE,
			stderr=None if kwargs.get("output", True) else subprocess.PIPE,
			shell=kwargs.get("shell", True),
			cwd=kwargs.get("cwd"),
			env=dict(os.environ, **env) if env else None,
			creationflags=subprocess.BELOW_NORMAL_PRIORITY_CLASS,
		)
		rc = proc.wait()
		if rc and kwargs.get("raise_err"):
			raise subprocess.CalledProcessError(rc, command)
		return rc

	frappe.commands.popen = popen

	# Text files are opened without an explicit encoding: the process must run in Python's UTF-8 mode
	# (PYTHONUTF8=1), otherwise Windows decodes them as cp1252.
	if not sys.flags.utf8_mode:
		print("frappe_win: warning: PYTHONUTF8=1 is not set; source files will be decoded as cp1252", file=sys.stderr)

if __name__ == "__main__":
	sys.argv = ["frappe.utils.bench_helper", *sys.argv[1:]]
	runpy.run_module("frappe.utils.bench_helper", run_name="__main__", alter_sys=True)
