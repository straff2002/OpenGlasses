#!/usr/bin/env node
// The Meta sign-in hand-off (Plan FZ, "Tests: auth forwarding").
//
// Two pages hand a returning Meta sign-in to the app: the homepage (index.html, inline script) for
// registrations that still name the old address, and /auth/meta/ (site/assets/auth-forward.js).
// Both must build the same scheme URL the app has always received, from any address they are
// served at, and both must do nothing on a plain visit.
//
//   node Scripts/tests/site-auth-forward.test.js

'use strict';
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const repo = path.resolve(__dirname, '..', '..');
const homeHTML = fs.readFileSync(path.join(repo, 'index.html'), 'utf8');
const homeScript = /<script>([\s\S]*?)<\/script>/.exec(homeHTML)[1];
const authScript = fs.readFileSync(path.join(repo, 'site', 'assets', 'auth-forward.js'), 'utf8');

const SCHEME = 'mwdat-688603774243722://';

function run(script, { pathname, search = '', hash = '' }) {
  const result = { replacedWith: null, className: '', timers: 0 };
  const sandbox = {
    window: {
      location: { pathname, search, hash, replace(url) { result.replacedWith = url; } },
    },
    document: {
      documentElement: { set className(v) { result.className = v; }, get className() { return result.className; } },
      getElementById() { return { style: {} }; },
    },
    setTimeout() { result.timers += 1; },
  };
  vm.runInNewContext(script, sandbox);
  result.appLink = sandbox.window.__avenkinAppLink;
  return result;
}

const returning = [
  { search: '?code=abc&state=xyz', hash: '' },
  { search: '', hash: '#access_token=abc' },
  { search: '?a=1', hash: '#b=2' },
];

// The homepage, at every address it has been served from.
for (const pathname of ['/', '/index.html', '/OpenGlasses/', '//', '']) {
  for (const { search, hash } of returning) {
    const r = run(homeScript, { pathname, search, hash });
    const expectedPath = pathname === '/index.html' ? '/OpenGlasses/index.html' : '/OpenGlasses/';
    assert.strictEqual(r.replacedWith, SCHEME + expectedPath + search + hash, `home at ${pathname}`);
    assert.strictEqual(r.className, 'returning');
  }
  const plain = run(homeScript, { pathname });
  assert.strictEqual(plain.replacedWith, null, `a plain visit to ${pathname} must not forward`);
  assert.strictEqual(plain.className, '');
  assert.strictEqual(plain.timers, 0);
}

// /auth/meta/: a fixed path, whatever the page's own address is.
for (const pathname of ['/auth/meta/', '/auth/meta/index.html', '/OpenGlasses/auth/meta/']) {
  for (const { search, hash } of returning) {
    const r = run(authScript, { pathname, search, hash });
    assert.strictEqual(r.replacedWith, SCHEME + '/OpenGlasses/' + search + hash, `auth page at ${pathname}`);
    assert.strictEqual(r.className, 'returning');
    // The app gets the same link from the new page as from the homepage at the site root.
    assert.strictEqual(r.replacedWith, run(homeScript, { pathname: '/', search, hash }).replacedWith);
  }
  const plain = run(authScript, { pathname });
  assert.strictEqual(plain.replacedWith, null, 'a plain visit must not forward');
  assert.strictEqual(plain.timers, 0);
}

console.log('site-auth-forward: PASS');
