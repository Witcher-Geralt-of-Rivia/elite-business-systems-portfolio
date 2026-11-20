// Portal behaviour: application links derived from this site's host name (no addresses in the source),
// availability from config.js (written at deploy time), live status from same-origin /status/* probes.
(function () {
  "use strict";
  var cfg = window.PORTAL_CONFIG || { apps: { crm: "live", pos: "preparing", erp: "planned" } };
  var host = location.hostname;
  var base = /^portfolio\./.test(host) ? host.replace(/^portfolio\./, "") : null;
  var entry = { crm: "/", pos: "/sign-in", erp: "/api/method/portfolio_sim.visitor.enter" };
  var labels = { live: "Live — read-only demo, no sign-up", preparing: "Being finalised — opens soon", planned: "In preparation" };

  function appUrl(app) { return base ? location.protocol + "//" + app + "." + base + (entry[app] || "/") : null; }

  document.querySelectorAll("[data-app-link]").forEach(function (a) {
    var app = a.getAttribute("data-app-link");
    var url = cfg.apps[app] === "live" ? appUrl(app) : null;
    if (url) { a.href = url; a.rel = "noopener"; }
    else { a.setAttribute("aria-disabled", "true"); a.removeAttribute("href"); a.textContent += " — soon"; }
  });
  document.querySelectorAll("[data-avail]").forEach(function (el) {
    el.textContent = labels[cfg.apps[el.getAttribute("data-avail")]] || "";
  });
  document.querySelectorAll(".shot img").forEach(function (img) {
    var mark = function () { img.closest("figure").classList.add("missing"); };
    if (img.complete && img.naturalWidth === 0) mark(); else img.addEventListener("error", mark);
  });
  var repo = document.querySelector("[data-repo-link]");
  if (repo && cfg.repo) { repo.href = cfg.repo; repo.rel = "noopener"; }

  function setStatus(app, state, text) {
    var li = document.querySelector('[data-status="' + app + '"]');
    if (!li) return;
    li.setAttribute("data-state", state);
    li.querySelector(".status-text").textContent = text;
  }
  function ago(iso) {
    var s = Math.max(0, (Date.now() - Date.parse(iso)) / 1000);
    if (s < 90) return "just now";
    if (s < 5400) return Math.round(s / 60) + " min ago";
    return Math.round(s / 3600) + " h ago";
  }
  function probe(app, url, describe) {
    if (cfg.apps[app] !== "live") { setStatus(app, "off", labels[cfg.apps[app]] ? labels[cfg.apps[app]].split(" —")[0].toLowerCase() : "offline"); return; }
    var ctl = "AbortController" in window ? new AbortController() : null;
    var timer = setTimeout(function () { ctl && ctl.abort(); }, 8000);
    fetch(url, { cache: "no-store", signal: ctl ? ctl.signal : undefined })
      .then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); })
      .then(function (j) { var d = describe(j); setStatus(app, d[0], d[1]); })
      .catch(function () { setStatus(app, "down", "status unavailable"); })
      .then(function () { clearTimeout(timer); });
  }
  probe("crm", "/status/crm", function (j) { return j.status === "ok" ? ["ok", "operational"] : ["warn", "degraded"]; });
  probe("pos", "/status/pos", function (j) {
    if (j.status !== "ok") return ["warn", "degraded"];
    var sim = j.simulation;
    if (!sim) return ["ok", "operational"];
    if (sim.paused) return ["warn", "operational · simulation paused"];
    return ["ok", "operational · simulation " + (sim.lag_seconds < 300 ? "live" : "synced " + ago(sim.processed_until))];
  });
  // ERP: /status/erp exists only after the owner-approved public activation (approval flag on the host).
  probe("erp", "/status/erp", function (j) {
    var h = j.message || {};
    if (!h.ok) return ["warn", "degraded"];
    var sim = h.simulation || {};
    if (sim.paused) return ["warn", "operational · simulation paused"];
    return ["ok", "operational · simulation " + (sim.live ? "live" : "idle")];
  });
  document.querySelectorAll("[data-show-when]").forEach(function (el) {
    var want = el.getAttribute("data-show-when").split(":");
    var hide = (cfg.apps[want[0]] === "live") !== (want[1] === "live");
    el.hidden = hide;
    el.style.display = hide ? "none" : "";
  });
})();
