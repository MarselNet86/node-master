# Adds the paywall inbound to a Remnawave config profile (web-tech §3.1) and rebuilds the
# paywall routing. The inbound is a copy of the profile's own inbound $src (keys, Reality
# site, xhttp obfuscation stay the node's) with its own tag, port and, for xhttp, path.
# A second run with the same tag replaces the inbound, so the filter is idempotent.
#
#   jq --arg src VLESS-REALITY-X --arg tag PAYWALL-IN-X --argjson port 8443 --arg path "" \
#      --slurpfile allow remnawave/paywall/allowlist.json \
#      -f remnawave/paywall/add-to-profile.jq profile-config.json
#
# Input: the profile's config object (GET /api/config-profiles/{uuid} → .response.config).
def is_paywall: (.inboundTag // []) | any(startswith("PAYWALL-IN"));

([.inbounds[] | select(.tag == $src)] | first // error("no inbound \($src) in the profile")) as $base
| ([.outbounds[] | select(.protocol == "freedom")] | first // error("no freedom outbound") | .tag) as $direct
| ([.outbounds[] | select(.protocol == "blackhole")] | first // error("no blackhole outbound") | .tag) as $block
| ($base
   | .tag = $tag
   | .port = $port
   | .settings.clients = []
   | .sniffing = {enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: true, metadataOnly: false}
   | if $path == "" then .
     elif .streamSettings.network == "xhttp" then .streamSettings.xhttpSettings.path = $path
     else error("path is for an xhttp inbound only") end
  ) as $paywall
| .inbounds = [(.inbounds[] | select(.tag != $tag)), $paywall]
| [.inbounds[].tag | select(startswith("PAYWALL-IN"))] as $tags
# The profile's own rules come first: they only block (private nets, torrents, QUIC on
# CDN profiles), and they keep doing it for the paywall. Unmatched traffic of the other
# inbounds still takes the first outbound, freedom.
| .routing.rules = [
    (.routing.rules // [])[] | select(is_paywall | not)
  ] + [
    {type: "field", inboundTag: $tags, domain: $allow[0].domains, outboundTag: $direct},
    {type: "field", inboundTag: $tags, ip: $allow[0].ips, outboundTag: $direct},
    {type: "field", inboundTag: $tags, outboundTag: $block}
  ]
