"""Production-safe authentication settings for public access (applied by activate-erp-public.ps1; idempotent).

Only Frappe's own settings are used (System Settings, Website Settings, User):
* login throttling, password policy, session expiry, no sign-up, no login by user name / mobile number;
* Administrator and the browser-test user can log in only from the host itself (User.restrict_ip = 127.0.0.1;
  behind the proxies the client address comes from X-Forwarded-For, trusted from loopback only);
* the browser-test user is disabled.
"""

from __future__ import annotations

import frappe

LOOPBACK = "127.0.0.1"
LOCAL_ONLY_USERS = ("Administrator", "e2e.viewer@sableridge.example")

SYSTEM_SETTINGS = {
	"allow_consecutive_login_attempts": 5,
	"allow_login_after_fail": 600,
	"enable_password_policy": 1,
	"minimum_password_score": "3",
	"session_expiry": "04:00",
	"allow_login_using_mobile_number": 0,
	"allow_login_using_user_name": 0,
	"disable_change_log_notification": 1,
}


def apply_public_settings() -> dict:
	applied: dict = {"system_settings": {}, "users": {}}
	ss = frappe.get_single("System Settings")
	meta = frappe.get_meta("System Settings")
	for field, value in SYSTEM_SETTINGS.items():
		if meta.has_field(field):
			ss.set(field, value)
			applied["system_settings"][field] = value
	ss.flags.ignore_mandatory = True
	ss.save(ignore_permissions=True)

	ws = frappe.get_single("Website Settings")
	if frappe.get_meta("Website Settings").has_field("disable_signup"):
		ws.disable_signup = 1
		ws.save(ignore_permissions=True)
		applied["website_signup_disabled"] = True

	for name in LOCAL_ONLY_USERS:
		if not frappe.db.exists("User", name):
			continue
		values = {"restrict_ip": LOOPBACK}
		if name != "Administrator":
			values["enabled"] = 0
		frappe.db.set_value("User", name, values, update_modified=False)
		applied["users"][name] = values
	frappe.db.commit()
	frappe.clear_cache()
	return applied
