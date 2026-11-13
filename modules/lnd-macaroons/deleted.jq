# Reads the output of `lncli deletemacaroonid` with `jq -s`.
# True only for exactly one object with a boolean `deleted`.
length == 1 and (.[0].deleted | type) == "boolean"
