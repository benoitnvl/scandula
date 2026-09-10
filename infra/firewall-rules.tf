# The baseline rules on the shared hub firewall policy (chosen 2026-09-10):
#
#   allow-spoke-to-spoke  network      any protocol/port, root prefix -> root prefix
#   allow-outbound-web    application  HTTP 80 / HTTPS 443, root prefix -> any FQDN
#
# Everything else is denied: that's Azure Firewall's default, and there's no inbound
# DNAT. Both rules follow ipam_root_prefix, so every spoke IPAM hands out is covered
# without being listed here.
#
# Outbound web is an *application* rule on purpose. Firewall Basic filters FQDNs only
# at the application level (SNI for HTTPS); network-level FQDN rules need the
# firewall's DNS proxy, which Basic doesn't have.
#
# Gated on secured_vwan_enabled like the rest of the hub: no policy, no rules.

resource "azurerm_firewall_policy_rule_collection_group" "baseline" {
  count = var.secured_vwan_enabled ? 1 : 0

  name               = "rcg-baseline"
  firewall_policy_id = azurerm_firewall_policy.this[0].id
  priority           = 1000

  network_rule_collection {
    name     = "allow-spoke-to-spoke"
    priority = 1100
    action   = "Allow"

    rule {
      name                  = "spokes-to-spokes"
      description           = "Private traffic between anything IPAM hands out, across both hubs."
      protocols             = ["Any"]
      source_addresses      = [var.ipam_root_prefix]
      destination_addresses = [var.ipam_root_prefix]
      destination_ports     = ["*"]
    }
  }

  application_rule_collection {
    name     = "allow-outbound-web"
    priority = 1200
    action   = "Allow"

    rule {
      name              = "spokes-to-internet-web"
      description       = "Outbound HTTP/HTTPS from spokes to any destination."
      source_addresses  = [var.ipam_root_prefix]
      destination_fqdns = ["*"]

      protocols {
        type = "Http"
        port = 80
      }

      protocols {
        type = "Https"
        port = 443
      }
    }
  }

  # Changing a policy while its firewalls are still being created tends to fail with
  # "another operation is in progress"; add the rules once the firewalls exist.
  depends_on = [azurerm_firewall.hub]
}
