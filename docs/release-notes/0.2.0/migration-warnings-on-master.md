#### Migration warnings on master

Unreleased configuration migrations now warn without blocking deployment or
requiring acknowledgement. Users following master must review them before
deploying; warnings cannot be acknowledged individually and repeat while
applicable. A `configVersion` newer than the latest finalized release is rejected.
Finalizing the release makes its notices blocking errors until acknowledged. See
the [upgrading guide](../../upgrading.md) for the version policy.
