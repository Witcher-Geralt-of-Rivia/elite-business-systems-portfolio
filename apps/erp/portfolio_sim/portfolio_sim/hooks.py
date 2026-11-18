app_name = "portfolio_sim"
app_title = "Portfolio Sim"
app_publisher = "Elite Business Systems Portfolio contributors"
app_description = "Sable Ridge Electronics Supply Co.: deterministic wholesale-distribution simulation for ERPNext v16"
app_email = "maintainers@example.org"
app_license = "gpl-3.0"

required_apps = ["erpnext"]

after_install = "portfolio_sim.install.after_install"

# The live worker: one short, locked tick per minute. It does nothing until the simulation is
# switched to live mode (`bench --site <site> portfolio-sim live on`) and while it is paused.
scheduler_events = {
	"cron": {
		"* * * * *": ["portfolio_sim.services.worker.tick"],
	},
}
