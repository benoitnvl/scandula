output "aggregate_ids" {
  description = "Aggregate name => NetBox id."
  value       = { for k, a in netbox_aggregate.this : k => a.id }
}

output "avnm_delegated_prefix_id" {
  description = "The NetBox record for the block delegated to AVNM."
  value       = netbox_prefix.avnm_delegated.id
}

output "reserved_prefixes" {
  description = "The on-premises ranges, in the shape infra's `reserved_prefixes` variable takes. NetBox is where this list is decided; the connectivity repo only enforces it."
  value       = sort([for p in values(var.onprem_prefixes) : p.prefix])
}

output "recorded_prefixes" {
  description = "Everything this root records, for a quick diff against what's really in NetBox."
  value = {
    aggregates = sort([for a in values(var.aggregates) : a.prefix])
    avnm       = sort(concat([var.avnm_delegated_prefix], values(var.avnm_region_prefixes)))
    onprem     = sort([for p in values(var.onprem_prefixes) : p.prefix])
  }
}
