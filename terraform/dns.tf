# DNS is deliberately not managed here: manage_dns defaults to false.
#
# As of writing, kmdndd.name.ng does not resolve publicly at all - every public
# resolver returns SERVFAIL - and there is no zone for it in this DigitalOcean
# account. Wherever its nameservers currently point, that is where the A record
# has to be created. Check with:
#
#   nslookup -type=NS kmdndd.name.ng 8.8.8.8
#
# Creating a DigitalOcean zone without the nameservers delegated here would be
# worse than doing nothing: the records would resolve nowhere, HTTP-01 would
# still fail, and the zone would be a second source of truth.
#
# If the nameservers are moved to ns1/ns2/ns3.digitalocean.com, set
# manage_dns = true and this file takes the zone over unchanged.

locals {
  managed_record_names = var.manage_dns ? var.dns_record_names : []

  # Computed either way - this is what `terraform output dns_records_to_create`
  # prints for you to enter wherever the zone actually lives.
  dns_records_to_create = [
    for name in var.dns_record_names : {
      type  = "A"
      name  = name
      host  = name == "@" ? var.domain : "${name}.${var.domain}"
      value = local.ingress_ip
      ttl   = 300
    }
  ]
}

resource "digitalocean_domain" "main" {
  count = var.manage_dns ? 1 : 0
  name  = var.domain
}

resource "digitalocean_record" "app" {
  for_each = toset(local.managed_record_names)

  domain = digitalocean_domain.main[0].name
  type   = "A"
  name   = each.value
  value  = local.ingress_ip
  ttl    = 300
}
