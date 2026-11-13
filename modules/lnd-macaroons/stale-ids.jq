# Reads the output of `lncli listmacaroonids` and prints the root key IDs
# from $first to $last that aren't in $current, one per line.
# The output is controlled by lnd. Fail unless it is exactly one object whose
# `root_key_ids` is an array of unique, canonical uint64 strings, so that only
# validated IDs reach `lncli deletemacaroonid`.

# \A and \z, because ^ and $ also match around a newline
def uint64: type == "string" and test("\\A(0|[1-9][0-9]{0,19})\\z")
  and (length < 20 or . <= "18446744073709551615");
# All IDs in the range have the same number of digits
def reserved: length == ($first | length) and . >= $first and . <= $last;

[inputs] as $outputs
| if ($outputs | length) != 1 or ($outputs[0] | type) != "object"
    or ($outputs[0].root_key_ids | type) != "array" then
    error("expected one object with a root_key_ids array")
  end
| $outputs[0].root_key_ids as $ids
| if any($ids[]; uint64 | not) or ($ids | unique | length) != ($ids | length) then
    error("expected unique uint64 strings in root_key_ids")
  end
| $ids[] | select(reserved and (IN($current[]) | not))
