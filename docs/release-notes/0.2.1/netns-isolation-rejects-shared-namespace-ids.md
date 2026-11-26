#### netns-isolation rejects shared namespace ids

Evaluation now fails when two entries of `nix-bitcoin.netns-isolation.services` have
the same `id`. Before, both namespaces got the same address and interface names.
The error lists the shared ids and the entries using them. This
matters only if you add or change entries yourself.
