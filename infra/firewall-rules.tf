# The hub firewall allows nothing by default (docs/zero-trust.md). Everything it does
# allow is named, one entry at a time, in variables.tf:
#
#   east_west_flows     spoke to spoke, per flow, with named protocols and ports
#   egress_https_fqdns  outbound 443, per destination
#   egress_http_fqdns   outbound 80, for certificate revocation only
#   egress_fqdn_tags    Microsoft-maintained destination sets (WindowsUpdate, ...)
#
# ⚠ Until 2026-09-14 this file held a blanket pair instead: any protocol and port
# between anything IPAM hands out, and 80/443 to any FQDN. Both widened by themselves
# as IPAM allocated, and nothing behind them inspected the traffic. Don't bring them
# back: add a named flow or a named destination.
#
# Everything not named here is denied, which is Azure Firewall's default, and there is
# no inbound DNAT. The rule collection group is only created when something is named:
# Azure rejects an empty one, and "no rules" is the correct state until a workload asks.

locals {
  egress_destinations = length(var.egress_https_fqdns) + length(var.egress_http_fqdns) + length(var.egress_fqdn_tags)
  firewall_rules      = var.secured_vwan_enabled && (length(var.east_west_flows) > 0 || local.egress_destinations > 0)
}

resource "azurerm_firewall_policy_rule_collection_group" "baseline" {
  count = local.firewall_rules ? 1 : 0

  name               = "rcg-baseline"
  firewall_policy_id = azurerm_firewall_policy.this[0].id
  priority           = 1000

  # East-west: one rule per approved flow, named after its key.
  dynamic "network_rule_collection" {
    for_each = length(var.east_west_flows) > 0 ? [1] : []

    content {
      name     = "allow-named-flows"
      priority = 1100
      action   = "Allow"

      dynamic "rule" {
        for_each = var.east_west_flows

        content {
          name                  = rule.key
          description           = rule.value.description
          protocols             = rule.value.protocols
          source_addresses      = rule.value.sources
          destination_addresses = rule.value.destinations
          destination_ports     = rule.value.ports
        }
      }
    }
  }

  # Egress: application rules, because Firewall Basic filters FQDNs only at the
  # application level (SNI for HTTPS). Network-level FQDN rules need the DNS proxy,
  # which Basic doesn't have.
  dynamic "application_rule_collection" {
    for_each = local.egress_destinations > 0 ? [1] : []

    content {
      name     = "allow-egress"
      priority = 1200
      action   = "Allow"

      dynamic "rule" {
        for_each = length(var.egress_https_fqdns) > 0 ? [1] : []

        content {
          name              = "https-allowlist"
          description       = "Outbound HTTPS, to these destinations only."
          source_addresses  = [var.ipam_root_prefix]
          destination_fqdns = var.egress_https_fqdns

          protocols {
            type = "Https"
            port = 443
          }
        }
      }

      # Plain HTTP is for certificate revocation (CRL, OCSP), which can't run over
      # HTTPS. Anything else belongs in the 443 list.
      dynamic "rule" {
        for_each = length(var.egress_http_fqdns) > 0 ? [1] : []

        content {
          name              = "http-revocation"
          description       = "Outbound HTTP 80, for certificate revocation endpoints."
          source_addresses  = [var.ipam_root_prefix]
          destination_fqdns = var.egress_http_fqdns

          protocols {
            type = "Http"
            port = 80
          }
        }
      }

      # Microsoft keeps the addresses behind each tag up to date.
      dynamic "rule" {
        for_each = length(var.egress_fqdn_tags) > 0 ? [1] : []

        content {
          name                  = "microsoft-fqdn-tags"
          description           = "Microsoft-maintained destination sets."
          source_addresses      = [var.ipam_root_prefix]
          destination_fqdn_tags = var.egress_fqdn_tags
        }
      }
    }
  }

  # Changing a policy while its firewalls are still being created tends to fail with
  # "another operation is in progress"; add the rules once the firewalls exist.
  depends_on = [azurerm_firewall.hub]
}
