# RPC calls that are safe for public use
#
# Not listed, because they are expensive, act on peers or touch a wallet:
# getblockfrompeer, gettxoutsetinfo, scantxoutset, getblocktemplate,
# fundrawtransaction. A service that calls one of these connects as its own
# RPC user, whose whitelist adds the method to this list (clightning.nix,
# mempool.nix, btcpayserver.nix). All services of the `public` user share its
# whitelist, so a method added there would reach every one of them.
[
  "echo"
  "getinfo"
  "getindexinfo"
  "help"
  "ping"
  "uptime"
  # Blockchain
  "getbestblockhash"
  "getblock"
  "getblockchaininfo"
  "getblockcount"
  "getblockfilter"
  "getblockhash"
  "getblockheader"
  "getblockstats"
  "getchaintips"
  "getchaintxstats"
  "getdeploymentinfo"
  "getdifficulty"
  "getmempoolancestors"
  "getmempooldescendants"
  "getmempoolentry"
  "getmempoolinfo"
  "getrawmempool"
  "gettxout"
  "gettxoutproof"
  "verifytxoutproof"
  # Mining
  "getmininginfo"
  "getnetworkhashps"
  # Network
  "getnetworkinfo"
  "getnodeaddresses"
  "getpeerinfo"
  # Rawtransactions
  "analyzepsbt"
  "combinepsbt"
  "combinerawtransaction"
  "converttopsbt"
  "createpsbt"
  "createrawtransaction"
  "decodepsbt"
  "decoderawtransaction"
  "decodescript"
  "finalizepsbt"
  "getrawtransaction"
  "joinpsbts"
  "sendrawtransaction"
  "signrawtransactionwithkey"
  "testmempoolaccept"
  "utxoupdatepsbt"
  # Util
  "createmultisig"
  "deriveaddresses"
  "estimatesmartfee"
  "getdescriptorinfo"
  "signmessagewithprivkey"
  "validateaddress"
  "verifymessage"
  # Zmq
  "getzmqnotifications"
]
