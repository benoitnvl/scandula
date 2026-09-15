# The address plan against a mocked netbox provider: no NetBox, no token, nothing
# written.
#
#   make netbox-test
#
# What this proves is the part that has to be right before anyone looks at NetBox:
# that the block delegated to AVNM is recorded as a container (so nobody hands out a
# piece of it from the wrong system), and that the plan can't be filed with ranges
# that overlap or sit outside the aggregates they claim to belong to.

mock_provider "netbox" {
  mock_resource "netbox_rir" {
    defaults = { id = "1" }
  }
  mock_resource "netbox_aggregate" {
    defaults = { id = "2" }
  }
  mock_resource "netbox_prefix" {
    defaults = { id = "3" }
  }
}

variables {
  aggregates = {
    rfc1918-10 = {
      prefix      = "10.0.0.0/8"
      rir         = "RFC 1918"
      description = "Aberdeen's whole internal plan."
    }
  }

  avnm_delegated_prefix = "10.64.0.0/12"

  avnm_region_prefixes = {
    eas  = "10.64.0.0/14"
    seas = "10.68.0.0/14"
  }

  onprem_prefixes = {
    aberdeen-office = {
      prefix      = "10.10.0.0/16"
      description = "Aberdeen office LAN."
    }
    datacentre = {
      prefix      = "10.20.0.0/16"
      description = "On-premises datacentre."
      status      = "reserved"
    }
  }
}

run "the_delegated_block_is_a_container" {
  command = apply

  assert {
    condition     = netbox_prefix.avnm_delegated.status == "container"
    error_message = "The AVNM block isn't a container. An 'active' prefix invites someone to allocate a piece of it in NetBox, which AVNM can't see and won't avoid."
  }

  assert {
    condition     = netbox_prefix.avnm_delegated.prefix == var.avnm_delegated_prefix
    error_message = "The recorded delegated block isn't the one that was asked for."
  }

  assert {
    condition = alltrue([
      for p in netbox_prefix.avnm_region : p.status == "container"
    ])
    error_message = "A region pool isn't recorded as a container."
  }

  assert {
    condition     = length(netbox_prefix.avnm_region) == length(var.avnm_region_prefixes)
    error_message = "Not every region pool reached NetBox."
  }
}

run "onprem_ranges_are_recorded_with_their_status" {
  command = apply

  assert {
    condition     = netbox_prefix.onprem["aberdeen-office"].status == "active"
    error_message = "The default status for an on-premises range should be active."
  }

  assert {
    condition     = netbox_prefix.onprem["datacentre"].status == "reserved"
    error_message = "An explicit status didn't reach NetBox."
  }

  # infra's reserved_prefixes is fed from here: the policy that denies these ranges
  # in Azure is only as good as this list.
  assert {
    condition     = output.reserved_prefixes == tolist(["10.10.0.0/16", "10.20.0.0/16"])
    error_message = "The reserved_prefixes output doesn't match the recorded on-premises ranges."
  }
}

run "aggregates_are_filed_under_their_rir" {
  command = apply

  assert {
    # rir_id is a number on the aggregate and a string on the RIR — NetBox ids are
    # strings everywhere in this provider except where they're referenced.
    condition     = tostring(netbox_aggregate.this["rfc1918-10"].rir_id) == netbox_rir.this["RFC 1918"].id
    error_message = "An aggregate is filed under the wrong registry."
  }

  assert {
    condition     = netbox_aggregate.this["rfc1918-10"].prefix == "10.0.0.0/8"
    error_message = "The aggregate prefix changed on its way to NetBox."
  }
}

# --- rejection runs: one per validation in variables.tf ------------------------------

run "reject_no_rirs" {
  command = plan
  variables { rirs = {} }
  expect_failures = [var.rirs]
}

run "reject_no_aggregates" {
  command = plan
  variables { aggregates = {} }
  expect_failures = [var.aggregates]
}

run "reject_aggregate_with_host_bits" {
  command = plan
  variables {
    aggregates = {
      bad = { prefix = "10.0.0.1/8", rir = "RFC 1918", description = "d" }
    }
  }
  expect_failures = [var.aggregates]
}

run "reject_aggregate_with_an_unknown_rir" {
  command = plan
  variables {
    aggregates = {
      bad = { prefix = "10.0.0.0/8", rir = "ARIN", description = "d" }
    }
  }
  expect_failures = [var.aggregates]
}

run "reject_delegated_prefix_with_host_bits" {
  command = plan
  variables { avnm_delegated_prefix = "10.64.0.1/12" }
  expect_failures = [var.avnm_delegated_prefix]
}

run "reject_delegated_prefix_outside_every_aggregate" {
  command = plan
  variables {
    avnm_delegated_prefix = "192.168.0.0/16"
    avnm_region_prefixes  = {}
    onprem_prefixes       = {}
  }
  expect_failures = [var.avnm_delegated_prefix]
}

run "reject_region_prefix_with_host_bits" {
  command = plan
  variables { avnm_region_prefixes = { eas = "10.64.0.1/14" } }
  expect_failures = [var.avnm_region_prefixes]
}

run "reject_region_prefix_outside_the_delegated_block" {
  command = plan
  variables { avnm_region_prefixes = { eas = "10.32.0.0/14" } }
  expect_failures = [var.avnm_region_prefixes]
}

run "reject_onprem_prefix_with_host_bits" {
  command = plan
  variables {
    onprem_prefixes = {
      bad = { prefix = "10.10.0.1/16", description = "d" }
    }
  }
  expect_failures = [var.onprem_prefixes]
}

run "reject_onprem_status_netbox_does_not_have" {
  command = plan
  variables {
    onprem_prefixes = {
      bad = { prefix = "10.10.0.0/16", description = "d", status = "container" }
    }
  }
  expect_failures = [var.onprem_prefixes]
}

# The collision the authority exists to catch: an on-premises range inside the block
# AVNM hands out. Nothing in Azure would notice until a gateway joined the two.
run "reject_onprem_range_that_overlaps_the_avnm_block" {
  command = plan
  variables {
    onprem_prefixes = {
      overlapping = { prefix = "10.65.0.0/16", description = "an on-prem range inside AVNM's block" }
    }
  }
  expect_failures = [var.onprem_prefixes]
}
