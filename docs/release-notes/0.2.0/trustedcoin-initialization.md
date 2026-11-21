#### TrustedCoin initialization

The TrustedCoin package applies two patches from the
[upstream startup fix](https://github.com/nbd-wtf/trustedcoin/pull/44) to prevent
initialization races and reporting height zero without a block source.
