# Both come from the environment, never from this repo:
#   NETBOX_SERVER_URL  https://<the app>.<region>.azurecontainerapps.io
#                      (netbox/platform's `netbox_url` output)
#   NETBOX_API_TOKEN   a token made in NetBox itself — see netbox/README.md
#
# The provider probes NetBox's version at startup and warns if it isn't one this
# release was tested against. skip_version_check exists for plans against a NetBox
# that isn't reachable; it hides a real signal, so it's a variable, not a default.
provider "netbox" {
  skip_version_check = var.skip_version_check
}
