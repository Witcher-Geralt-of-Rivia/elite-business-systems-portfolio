// Native-Windows launcher for Frappe's realtime (Socket.IO) server. No upstream file is changed.
//
// Adaptation: upstream apps/frappe/realtime/index.js calls server.listen(port), which listens on ALL interfaces
// (on Linux, production benches put it behind nginx and a firewall). Here the listener is pinned to loopback; the
// private proxy (Caddy, 127.0.0.1) forwards /socket.io to it. Everything else is Frappe's own server.
//
// Environment: FRAPPE_BENCH_ROOT (bench directory, read by Frappe's node_utils), optional FRAPPE_SOCKETIO_HOST.
// Dependencies (socket.io, @redis/client, cookie) resolve through NODE_PATH (install-erp-services.ps1).
"use strict";
const http = require("node:http");
const path = require("node:path");

const host = process.env.FRAPPE_SOCKETIO_HOST || "127.0.0.1";
const listen = http.Server.prototype.listen;
http.Server.prototype.listen = function (...args) {
	const first = args[0];
	if (typeof first === "number" || (typeof first === "string" && /^\d+$/.test(first))) {
		const callback = args.find((a) => typeof a === "function");
		return listen.call(this, Number(first), host, callback);
	}
	return listen.apply(this, args);
};

const bench = process.env.FRAPPE_BENCH_ROOT;
if (!bench) {
	console.error("realtime_win: FRAPPE_BENCH_ROOT is not set");
	process.exit(2);
}
process.on("SIGINT", () => process.exit(0)); // service stop (Ctrl+C from the service wrapper)
require(path.join(bench, "apps", "frappe", "realtime", "index.js"));
