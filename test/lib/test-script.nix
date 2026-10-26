# Keep the suite in the driver's shared namespace, including in the REPL.
# Concatenation also lets the NixOS driver's lint/type checks see every body.
# File order only affects registration; tests.py defines execution order.
builtins.concatStringsSep "\n\n" ((map builtins.readFile [
  ../tests.py
  ../suite/helpers.py
  ../suite/services.py
  ../suite/security.py
  ../suite/networking.py
  ../suite/backups.py
  ../suite/restarts.py
  ../suite/regtest.py
]) ++ [ "validate_test_plan()" ])
