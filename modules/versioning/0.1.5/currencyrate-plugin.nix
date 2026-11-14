{ config, ... }:

{
  condition = config.services.clightning.plugins.currencyrate.enable;
  message = ''
    The Python currencyrate plugin has been replaced by Core Lightning's Rust
    cln-currencyrate plugin. Keep `services.clightning.plugins.currencyrate.enable`,
    but replace `currencyrates` with `listcurrencyrates` (fiat per BTC rather
    than msat per fiat unit). `currencyconvert` now returns a numeric `msat`.
    Rename `add-source` and `disable-source` to `currencyrate-add-source` and
    `currencyrate-disable-source`. The plugin now follows CLN's configured proxy.
  '';
}
