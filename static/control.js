// Lockstep control pane (contract C-P3.1 §3). Every value is written with
// textContent; this script builds no markup from strings and runs no code it
// did not ship with. The session lives only in this origin's localStorage and
// is sent only as the X-Lockstep-Session header, by this script, to this pane.
(function () {
  'use strict';

  var KEY = 'lockstep.control.session';
  var app = document.getElementById('app');

  // The sign-in token arrives in the fragment of /sign-in. Take it, then remove
  // it from the address bar and from this history entry before anything else.
  var token = null;
  if (window.location.pathname === '/sign-in' && window.location.hash.length > 1) {
    token = window.location.hash.slice(1);
  }
  window.history.replaceState(null, '', '/');

  function storedSession() {
    try { return window.localStorage.getItem(KEY); } catch (e) { return null; }
  }
  function storeSession(value) {
    try { window.localStorage.setItem(KEY, value); } catch (e) { /* storage unavailable: signed out next time */ }
  }
  function forgetSession() {
    try { window.localStorage.removeItem(KEY); } catch (e) { /* nothing stored */ }
  }

  function node(tag, className, text) {
    var element = document.createElement(tag);
    if (className) { element.className = className; }
    if (text !== undefined && text !== null) { element.textContent = text; }
    return element;
  }
  function clear() {
    while (app.firstChild) { app.removeChild(app.firstChild); }
  }
  function heading() {
    app.appendChild(node('h1', null, 'Lockstep'));
  }

  var notice = null;
  function showNotice() {
    if (notice) { app.appendChild(node('p', 'ls-notice', notice)); }
  }

  function renderSignedOut() {
    clear();
    heading();
    showNotice();
    app.appendChild(node('p', null, 'You are signed out of this window.'));
    app.appendChild(node('p', null, 'To open Lockstep, run lockstep on this computer.'));
  }

  function renderMessage(text) {
    clear();
    heading();
    showNotice();
    app.appendChild(node('h2', null, 'This computer'));
    app.appendChild(node('p', null, text));
    actions(true);
  }

  function api(method, path, body) {
    var headers = { 'X-Lockstep-Session': storedSession() || '' };
    if (body !== undefined) { headers['Content-Type'] = 'text/plain'; }
    return window.fetch(path, {
      method: method,
      headers: headers,
      body: body,
      credentials: 'omit',
      cache: 'no-store',
      redirect: 'error'
    });
  }

  function signOut() {
    api('POST', '/api/sign-out', '').catch(function () { return null; }).then(function () {
      forgetSession();
      window.location.replace('/');
    });
  }

  function actions(withCheck) {
    var row = node('div', 'ls-actions');
    if (withCheck) {
      var check = node('button', 'ls-primary', 'Check again');
      check.id = 'check-again';
      check.type = 'button';
      check.addEventListener('click', function () { window.location.reload(); });
      row.appendChild(check);
    }
    var out = node('button', null, 'Sign out');
    out.id = 'sign-out';
    out.type = 'button';
    out.addEventListener('click', signOut);
    row.appendChild(out);
    app.appendChild(row);
  }

  var DATABASE_REASONS = {
    database_missing: 'the database does not exist yet',
    database_unreachable: 'the database server is not running or cannot be reached',
    schema_behind: 'the database needs an upgrade before this version of Lockstep can use it',
    schema_invalid: 'the database belongs to a different version of Lockstep',
    authentication_failed: "Lockstep's database password was refused",
    database_not_configured: 'Lockstep has not been set up yet',
    database_error: 'the database reported an error'
  };

  function item(list, label, state, explanation, good) {
    var li = node('li', good ? 'ls-good' : 'ls-attention');
    li.appendChild(node('span', 'ls-label', label));
    var value = node('span', 'ls-state', state);
    if (explanation) { value.appendChild(node('span', 'ls-explain', explanation)); }
    li.appendChild(value);
    list.appendChild(li);
  }

  function renderStatus(result) {
    var f = result.fields || {};
    clear();
    heading();
    showNotice();
    app.appendChild(node('h2', null, 'This computer'));
    if (result.outcome !== 'ok') {
      app.appendChild(node('p', 'ls-notice', 'Lockstep could not finish checking this computer (' + result.outcome + ').'));
    }
    var list = node('ul', 'ls-status');

    if (f['install.present'] === 'yes') {
      var commit = f['install.commit'] && f['install.commit'] !== 'unknown' ? f['install.commit'].slice(0, 7) : null;
      item(list, 'Application', 'Installed', commit ? 'Version ' + commit : null, true);
    } else if (f['install.present'] === 'no') {
      item(list, 'Application', 'Not installed yet', 'Installing from this window comes in a later version.', false);
    } else {
      item(list, 'Application', 'Unknown', null, false);
    }

    var service = f['service.state'];
    if (service === 'running') {
      item(list, 'Service', 'Running', null, true);
    } else if (service === 'stopped') {
      item(list, 'Service', 'Not running', null, false);
    } else if (service === 'absent') {
      item(list, 'Service', 'Not set up', 'It starts automatically once the application and database are ready.', false);
    } else {
      item(list, 'Service', 'Unknown', null, false);
    }

    var readiness = f['database.readiness'];
    var reason = f['database.reason'];
    if (readiness === 'ready') {
      item(list, 'Database', 'Ready', null, true);
    } else if (readiness === 'not-ready') {
      item(list, 'Database', 'Not ready', DATABASE_REASONS[reason] || 'the database is not ready', false);
    } else if (reason === 'not-installed') {
      item(list, 'Database', 'Unknown', 'Lockstep is not installed yet, so the database was not checked.', false);
    } else {
      item(list, 'Database', 'Unknown', null, false);
    }
    app.appendChild(list);

    if (result.detail) {
      app.appendChild(node('p', 'ls-muted', 'What Lockstep saw: ' + result.detail));
    }
    var when = new Date((result.finished || 0) * 1000);
    app.appendChild(node('p', 'ls-muted', 'Checked at ' + when.toLocaleTimeString() + '.'));
    actions(true);

    var details = node('details');
    details.appendChild(node('summary', null, 'Technical details'));
    var facts = node('dl', 'ls-facts');
    Object.keys(f).sort().forEach(function (name) {
      facts.appendChild(node('dt', null, name));
      facts.appendChild(node('dd', null, f[name]));
    });
    facts.appendChild(node('dt', null, 'outcome'));
    facts.appendChild(node('dd', null, result.outcome + (result.reason ? ' (' + result.reason + ')' : '')));
    details.appendChild(facts);
    app.appendChild(details);
  }

  function wait(ms) {
    return new Promise(function (resolve) { window.setTimeout(resolve, ms); });
  }

  async function poll(id) {
    var started = Date.now();
    var slowShown = false;
    while (Date.now() - started < 120000) {
      var response = await api('GET', '/api/requests/' + id);
      if (response.status === 401) { forgetSession(); renderSignedOut(); return; }
      if (!response.ok) { renderMessage('Lockstep could not read the answer from this computer.'); return; }
      var body = await response.json();
      if (body.state === 'done') { renderStatus(body); return; }
      if (body.state === 'untrusted') { renderMessage('The answer from this computer could not be verified, so it is not shown.'); return; }
      if (!slowShown && Date.now() - started > 15000) {
        slowShown = true;
        renderMessage('Still checking. If this does not change, run lockstep again on this computer.');
      }
      await wait(400);
    }
    renderMessage("Lockstep's helper on this computer is not answering. Run lockstep again on this computer.");
  }

  async function check() {
    clear();
    heading();
    showNotice();
    app.appendChild(node('p', null, 'Checking this computer…'));
    var response = await api('POST', '/api/requests', 'status');
    if (response.status === 401) { forgetSession(); renderSignedOut(); return; }
    if (response.status === 503) {
      renderMessage("Lockstep's helper on this computer is not running. Run lockstep again on this computer.");
      return;
    }
    if (!response.ok) { renderMessage('Lockstep could not ask this computer for its state.'); return; }
    var body = await response.json();
    await poll(body.id);
  }

  async function start() {
    if (token) {
      var sent = token;
      token = null;
      var response = await window.fetch('/api/session', {
        method: 'POST',
        headers: { 'Content-Type': 'text/plain' },
        body: sent,
        credentials: 'omit',
        cache: 'no-store',
        redirect: 'error'
      });
      sent = null;
      if (response.ok) {
        var body = await response.json();
        storeSession(body.session);
      } else {
        notice = 'This sign-in link was already used or has expired. Run lockstep on this computer to open a new one.';
      }
    }
    if (!storedSession()) { renderSignedOut(); return; }
    await check();
  }

  start().catch(function () {
    renderMessage('Lockstep could not reach its control pane. Run lockstep again on this computer.');
  });
}());
