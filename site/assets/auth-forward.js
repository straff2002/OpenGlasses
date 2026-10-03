// Meta sign-in returns to /auth/meta/ with its result in the query string or fragment, and this
// script hands that result to the app through its URL scheme (Plan FZ, "The Meta auth redirect").
//
// The scheme URL is built from a FIXED path. The Meta registration originally named the page at
// straff2002.github.io/OpenGlasses/, so the app has always been handed "/OpenGlasses/" as the path;
// this page sends the same path wherever it is served from. The homepage (/) keeps its own inline
// copy of this hand-off for registrations that still name the old address; the two are checked
// against each other by Scripts/tests/site-auth-forward.test.js.
//
// Nothing is sent anywhere and nothing is stored. A plain visit (no query, no fragment) does
// nothing and the page explains what it is for.
(function () {
  var search = window.location.search || '';
  var hash = window.location.hash || '';
  var appScheme = 'mwdat-688603774243722://' + '/OpenGlasses/' + search + hash;
  window.__avenkinAppLink = appScheme;
  if (!search && !hash) return;

  document.documentElement.className = 'returning';
  window.location.replace(appScheme);

  // Fallback if the app did not open
  setTimeout(function () {
    document.getElementById('status').textContent =
      'If the app did not open, make sure it is installed and try again.';
    document.getElementById('manual').style.display = 'block';
    document.getElementById('manual-link').href = appScheme;
  }, 2000);
})();
