// Makes RTL check TLS certificates.
//
// RTL sends the lnd admin macaroon and the clightning admin rune to its
// backends with `rejectUnauthorized: false`, and it has no option to set a CA.
// So a local process that takes a backend's port while the backend isn't
// listening would get the credential.
// Node preloads this file in RTL, see `NODE_OPTIONS` in ../rtl.nix. It wraps
// `tls.connect`, where all of RTL's HTTPS and WebSocket connections start.
// A connection to a backend's address and port must present that backend's
// pinned cert, its own server cert. Every other connection gets the normal
// checks of the cert and the hostname against the system CAs. So a backend
// reached through another address or a proxy fails only because the system
// CAs don't trust its cert.
// RTL doesn't start when `LN_SERVER_URL` or `LND_SERVER_URL` is set. RTL uses
// them instead of the configured backend URLs, also with plain HTTP, which
// never reaches `tls.connect`.
// TODO-EXTERNAL: Remove this file once RTL can verify its backends'
// certificates itself.
'use strict';

const { X509Certificate } = require('node:crypto');
const fs = require('node:fs');
const { syncBuiltinESMExports } = require('node:module');
const net = require('node:net');
const tls = require('node:tls');

// The path of a JSON file that maps each backend's URL to its cert file (PEM)
const pinsFileVar = 'RTL_BACKEND_CERTS';
const httpsPort = 443;

// A key like "127.0.0.1:8080". RTL's clients take the host from a parsed URL,
// which has IPv6 addresses in brackets, and pass it on without them.
function targetKey(host, port) {
  const bareHost = String(host).replace(/^\[(.*)\]$/, '$1').toLowerCase();
  return `${bareHost}:${Number(port)}`;
}

// Returns only the file's first cert. Node would trust every cert in the file.
function readCert(certFile) {
  const pem = fs.readFileSync(certFile, 'utf8');
  try {
    return new X509Certificate(pem).toString();
  } catch (error) {
    throw new Error(`'${certFile}' holds no PEM certificate`, { cause: error });
  }
}

function parseBackendUrl(url) {
  const { protocol, hostname, port } = new URL(url);
  if (protocol !== 'https:' || !hostname) {
    throw new Error(`'${url}' isn't an HTTPS URL with a host`);
  }
  return targetKey(hostname, port || httpsPort);
}

// Throws when anything is missing or malformed, so that RTL doesn't start
function loadPins() {
  const pinsFile = process.env[pinsFileVar];
  if (!pinsFile) {
    throw new Error(`${pinsFileVar} is not set`);
  }
  const certFiles = JSON.parse(fs.readFileSync(pinsFile, 'utf8'));
  const isMap = typeof certFiles === 'object' && certFiles !== null
    && !Array.isArray(certFiles);
  const entries = isMap ? Object.entries(certFiles) : [];
  const hasNonString = entries.some(([, certFile]) => typeof certFile !== 'string');
  if (entries.length === 0 || hasNonString) {
    throw new Error(`'${pinsFile}' doesn't map backend URLs to cert files`);
  }
  return new Map(entries.map(([url, certFile]) => [
    parseBackendUrl(url),
    tls.createSecureContext({
      // Replaces Node's default CAs, so only certs that chain to the pinned cert pass
      ca: readCert(certFile),
      // The pinned cert passes even when a CA issued it, like clnrest's cert
      allowPartialTrustChain: true,
    }),
  ]));
}

// The options that `tls.connect` makes of its arguments, like
// `normalizeConnectArgs` in Node's lib/internal/tls/wrap.js: an options object,
// or a port and host with an optional options object after them, and an
// optional callback last
function connectArgs(args) {
  const [options, callback] = net._normalizeArgs(args);
  const isObject = (arg) => typeof arg === 'object' && arg !== null;
  const extraOptions = isObject(args[1]) ? args[1] : args[2];
  return [{ ...options, ...extraOptions }, callback];
}

// For a backend: only its pinned cert, instead of the caller's context and CAs.
// CLN's clnrest certs name `cln` and `localhost`, not always the address that
// RTL connects to, so the pinned cert alone decides which cert passes.
function pinnedOptions(context) {
  return { secureContext: context, checkServerIdentity: () => undefined };
}

function refuseUrlOverrides() {
  for (const name of ['LN_SERVER_URL', 'LND_SERVER_URL']) {
    // RTL ignores a blank value
    if (process.env[name]?.trim()) {
      throw new Error(`${name} is set. RTL must use only the configured backend URLs.`);
    }
  }
}

refuseUrlOverrides();
const pins = loadPins();
const { connect } = tls;

tls.connect = function connectVerified(...args) {
  const [options, callback] = connectArgs(args);
  const context = pins.get(targetKey(options.host || 'localhost', options.port));
  return connect.call(this, {
    ...options,
    ...(context && pinnedOptions(context)),
    // RTL passes `false`. With `true`, Node destroys the socket as soon as the
    // handshake ends with a cert that fails the check, before it sends any
    // request data.
    rejectUnauthorized: true,
  }, callback);
};

// Also for ES modules that import `connect` by name
syncBuiltinESMExports();
