# Reads the output of `lncli listpermissions` and prints the RPCs that lnd
# registers, one per line.
# The output is controlled by lnd. Fail unless it is exactly one object whose
# `method_permissions` is a non-empty object, so that an unexpected output
# can't leave out the optional permissions of RPCs that lnd has.

[inputs] as $outputs
| if ($outputs | length) != 1 or ($outputs[0] | type) != "object"
    or ($outputs[0].method_permissions | type) != "object"
    or ($outputs[0].method_permissions | length) == 0 then
    error("expected one object with a non-empty method_permissions object")
  end
| $outputs[0].method_permissions | keys[]
