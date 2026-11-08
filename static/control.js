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

  function item(list, label, state, explanation, good, buttons) {
    var li = node('li', good ? 'ls-good' : 'ls-attention');
    li.appendChild(node('span', 'ls-label', label));
    var value = node('span', 'ls-state', state);
    if (explanation) { value.appendChild(node('span', 'ls-explain', explanation)); }
    if (buttons && buttons.length) {
      var row = node('span', 'ls-actions');
      buttons.forEach(function (b) { row.appendChild(b); });
      value.appendChild(row);
    }
    li.appendChild(value);
    list.appendChild(li);
  }

  // ---- Start, stop and restart (C-P3.2). One operation at a time.

  var afterNotice = null;
  var lifecycleButtons = [];
  var WORKING = {
    'service-start': 'Starting the service…',
    'service-stop': 'Stopping the service…',
    'service-restart': 'Restarting the service…',
    'database-start': 'Starting the database…',
    'database-stop': 'Stopping the database…'
  };
  var DONE = {
    'service-start': 'Done: the service was started.',
    'service-stop': 'Done: the service was stopped.',
    'service-restart': 'Done: the service was restarted.',
    'database-start': 'Done: the database was started.',
    'database-stop': 'Done: the database was stopped.'
  };
  var EXPECT = {
    'service-start': 'not-running',
    'service-stop': 'running',
    'service-restart': 'running',
    'database-start': 'not-running',
    'database-stop': 'service-not-running'
  };

  function lifecycleButton(op, label, enabled) {
    var b = node('button', null, label);
    b.id = op;
    b.type = 'button';
    b.disabled = !enabled;
    b.addEventListener('click', function () { runLifecycle(op); });
    lifecycleButtons.push(b);
    return b;
  }

  function failureText(result) {
    switch (result.outcome === 'refused' ? result.reason : result.outcome) {
      case 'state-changed': return 'Nothing was done: the state had already changed. The current state is shown below.';
      case 'not-compatible': return 'Nothing was done: the installed application and the database do not match. Upgrading from this window comes in a later version.';
      case 'not-managed': return 'Nothing was done: this database is not managed from this window.';
      case 'timed-out': return 'That took too long and was stopped. The current state is shown below.';
      case 'interrupted': return 'That was interrupted. The current state is shown below.';
      case 'untrusted': return 'The answer could not be verified, so it is not shown.';
      default: return 'It did not work.' + (result.detail ? ' What Lockstep saw: ' + result.detail : '');
    }
  }

  async function runLifecycle(op) {
    lifecycleButtons.forEach(function (b) { b.disabled = true; });
    var working = node('p', 'ls-notice', WORKING[op]);
    app.insertBefore(working, app.children[1] || null);
    var response = await api('POST', '/api/lifecycle', op + ' ' + EXPECT[op]);
    if (response.status === 401) { forgetSession(); renderSignedOut(); return; }
    if (response.status === 409) {
      afterNotice = 'Another operation is still running. Wait for it to finish, then check again.';
      await check();
      return;
    }
    if (!response.ok) {
      afterNotice = 'Lockstep could not send that request to this computer.';
      await check();
      return;
    }
    var body = await response.json();
    var result = await waitForResult(body.id, 300000);
    if (result === 'signed-out') { return; }
    if (!result) {
      afterNotice = 'That has not finished reporting back. Check again in a moment.';
    } else {
      afterNotice = result.outcome === 'ok' ? DONE[op] : failureText(result);
    }
    await check();
  }

  async function waitForResult(id, limit) {
    var started = Date.now();
    while (Date.now() - started < limit) {
      var response = await api('GET', '/api/requests/' + id);
      if (response.status === 401) { forgetSession(); renderSignedOut(); return 'signed-out'; }
      if (!response.ok) { return null; }
      var body = await response.json();
      if (body.state === 'done') { return body; }
      if (body.state === 'untrusted') { return { outcome: 'untrusted' }; }
      await wait(500);
    }
    return null;
  }

  // ---- Open Lockstep (C-P3.4 A3). The helper asks the running service for a
  // one-time sign-in; the pane hands its address to this page once.

  async function openApplication() {
    lifecycleButtons.forEach(function (b) { b.disabled = true; });
    var working = node('p', 'ls-notice', 'Opening Lockstep…');
    app.insertBefore(working, app.children[1] || null);
    var response = await api('POST', '/api/open-application', '');
    if (response.status === 401) { forgetSession(); renderSignedOut(); return; }
    if (!response.ok) {
      afterNotice = response.status === 409
        ? 'Another operation is still running. Wait for it to finish, then try again.'
        : 'Lockstep could not send that request to this computer.';
      await check();
      return;
    }
    var body = await response.json();
    var result = await waitForResult(body.id, 60000);
    if (result === 'signed-out') { return; }
    if (result && result.outcome === 'ok') {
      var handover = await api('GET', '/api/handover/' + body.id);
      if (handover.status === 401) { forgetSession(); renderSignedOut(); return; }
      if (handover.ok) {
        var target = await handover.json();
        if (typeof target.url === 'string' && /^http:\/\/127\.0\.0\.1:[0-9]+\/app\/sign-in#[A-Za-z0-9_-]+$/.test(target.url)) {
          window.location.assign(target.url);
          return;
        }
      }
      afterNotice = 'Lockstep could not open its window. Try again.';
    } else if (!result) {
      afterNotice = 'Lockstep did not answer in time. Try again in a moment.';
    } else if (result.outcome === 'refused' && result.reason === 'state-changed') {
      afterNotice = 'Lockstep is not running or not answering, so it cannot be opened. Start it first.';
    } else {
      afterNotice = failureText(result);
    }
    await check();
  }

  // ---- Project folders (C-P3.5 J5, J6). Only this computer's helper changes the list.

  var FOLDER_REASONS = {
    'state-changed': 'Nothing was done: the list of folders changed since it was shown. The current list is shown below.',
    'unusable-path': 'Nothing was done: Lockstep can only use a full folder path made of plain letters, digits, spaces and . _ - / (no : or ,).',
    'folder-missing': 'Nothing was done: there is no folder at that path.',
    'not-a-folder': 'Nothing was done: that path is a file, not a folder.',
    'outside-home': 'Nothing was done: Lockstep only uses folders inside your home folder.',
    'home-folder': 'Nothing was done: Lockstep does not use your whole home folder. Choose the folder of one project.',
    'inside-lockstep': 'Nothing was done: that folder is part of Lockstep itself.',
    'already-listed': 'Nothing was done: Lockstep can already see that folder.',
    'overlaps-listed': 'Nothing was done: that folder is inside, or contains, a folder Lockstep can already see.',
    'list-full': 'Nothing was done: Lockstep can see at most 15 added folders.'
  };

  function emptyList(list) {
    while (list.firstChild) { list.removeChild(list.firstChild); }
  }

  function plainFolderPath(path) {
    return /^\/[ -~]*$/.test(path) && !/[:,]/.test(path) && !/\/$/.test(path) &&
      path.split('/').slice(1).every(function (s) { return s !== '' && s !== '.' && s !== '..'; });
  }

  function renderFolders(serviceRunning) {
    var section = node('section');
    section.appendChild(node('h2', null, 'Project folders'));
    section.appendChild(node('p', null, 'These are the only folders on this computer that Lockstep can see. New projects get a folder inside the first one. Folders you add can be read by Lockstep but not changed.'));
    var list = node('ul', 'ls-status');
    list.appendChild(node('li', 'ls-muted', 'Loading the list…'));
    section.appendChild(list);
    var label = node('label', 'ls-label', 'Add a folder that is already on this computer (its full path, for example /Users/you/code/my-site)');
    label.setAttribute('for', 'folder-path');
    section.appendChild(label);
    var input = node('input');
    input.id = 'folder-path';
    input.type = 'text';
    input.autocomplete = 'off';
    input.spellcheck = false;
    section.appendChild(input);
    var review = node('button', null, 'Review…');
    review.id = 'folder-review';
    review.type = 'button';
    lifecycleButtons.push(review);
    var row = node('div', 'ls-actions');
    row.appendChild(review);
    section.appendChild(row);
    var digest = null;
    review.addEventListener('click', function () {
      var path = input.value.trim();
      var old = section.querySelector('.ls-notice');
      if (old) { old.parentNode.removeChild(old); }
      if (!plainFolderPath(path)) {
        section.appendChild(node('p', 'ls-notice', FOLDER_REASONS['unusable-path']));
        return;
      }
      section.appendChild(confirmPanel(
        'Lockstep will be able to see this folder: ' + path + '. It can read it but not change it.' +
          (serviceRunning ? ' Lockstep restarts so that it can see the folder.' : ''),
        'add-folder', 'Add folder',
        function () { runFolder(digest, path); }));
    });
    api('GET', '/api/folders').then(function (response) {
      if (response.status === 401) { forgetSession(); renderSignedOut(); return null; }
      return response.ok ? response.json() : null;
    }).then(function (body) {
      emptyList(list);
      if (!body) { list.appendChild(node('li', 'ls-attention', 'The list could not be read.')); return; }
      digest = body.digest;
      if (!body.folders.length) {
        list.appendChild(node('li', 'ls-attention', 'Lockstep cannot see any folder yet.'));
      }
      body.folders.forEach(function (folder) {
        item(list, folder.mode === 'rw' ? 'For new projects' : 'Added', folder.path,
          folder.mode === 'rw' ? 'Lockstep makes new project folders here.' : 'Lockstep can read this folder but not change it.', true);
      });
    }).catch(function () {
      emptyList(list);
      list.appendChild(node('li', 'ls-attention', 'The list could not be read.'));
    });
    return section;
  }

  async function runFolder(digest, path) {
    lifecycleButtons.forEach(function (b) { b.disabled = true; });
    var working = node('p', 'ls-notice', 'Adding the folder…');
    app.insertBefore(working, app.children[1] || null);
    if (!digest) {
      afterNotice = 'The list of folders could not be read, so nothing was done. Check again.';
      await check();
      return;
    }
    var response = await api('POST', '/api/folders', 'add-folder ' + digest + ' ' + path);
    if (response.status === 401) { forgetSession(); renderSignedOut(); return; }
    if (!response.ok) {
      afterNotice = response.status === 409
        ? 'Another operation is still running. Wait for it to finish, then try again.'
        : response.status === 400 ? FOLDER_REASONS['unusable-path'] : 'Lockstep could not send that request to this computer.';
      await check();
      return;
    }
    var body = await response.json();
    var result = await waitForResult(body.id, 300000);
    if (result === 'signed-out') { return; }
    if (!result) {
      afterNotice = 'That has not finished reporting back. Check again in a moment.';
    } else if (result.outcome === 'ok') {
      var restart = (result.fields || {})['service.restart'];
      afterNotice = 'Done: Lockstep can now see ' + path + '.' +
        (restart === 'failed' ? ' The service could not be restarted, so it will see the folder after its next start.' : '');
    } else if (result.outcome === 'refused' && FOLDER_REASONS[result.reason]) {
      afterNotice = FOLDER_REASONS[result.reason];
    } else {
      afterNotice = failureText(result);
    }
    await check();
  }

  // ---- Install, upgrade and recovery (C-P3.3). Every change is reviewed, then confirmed.

  async function runInstall(op, expect, doneText) {
    lifecycleButtons.forEach(function (b) { b.disabled = true; });
    var working = node('p', 'ls-notice', op === 'prepare-candidate'
      ? 'Preparing the new version. This builds it and can take several minutes; nothing changes yet.'
      : op === 'apply-candidate' ? 'Installing. Keep this window open or come back later: Lockstep carries on without it.'
        : 'Restoring the previous version…');
    app.insertBefore(working, app.children[1] || null);
    var response = await api('POST', '/api/install', op + ' ' + expect);
    if (response.status === 401) { forgetSession(); renderSignedOut(); return; }
    if (response.status === 409) {
      afterNotice = 'Another operation is still running. Wait for it to finish, then check again.';
      await check();
      return;
    }
    if (!response.ok) {
      afterNotice = 'Lockstep could not send that request to this computer.';
      await check();
      return;
    }
    var body = await response.json();
    var result = await waitForResult(body.id, 3600000);
    if (result === 'signed-out') { return; }
    if (!result) {
      afterNotice = 'That has not finished yet. Check again in a few minutes.';
    } else if (result.outcome === 'ok') {
      afterNotice = doneText;
    } else if (result.outcome === 'refused' && result.reason === 'dirty-checkout') {
      afterNotice = 'Nothing was done: this copy of Lockstep has changes that are not saved in Git, so it cannot be installed as a version.';
    } else if (result.outcome === 'refused' && result.reason === 'database-ahead') {
      afterNotice = 'Nothing was done: the database belongs to a newer version of Lockstep than this one. Lockstep never installs an older version over it.';
    } else {
      afterNotice = failureText(result);
    }
    await check();
  }

  function confirmPanel(text, buttonId, label, action) {
    var panel = node('div', 'ls-notice');
    panel.appendChild(node('p', null, text));
    var row = node('div', 'ls-actions');
    var yes = node('button', 'ls-primary', label);
    yes.id = buttonId;
    yes.type = 'button';
    yes.addEventListener('click', action);
    lifecycleButtons.push(yes);
    var no = node('button', null, 'Cancel');
    no.type = 'button';
    no.addEventListener('click', function () { panel.parentNode.removeChild(panel); });
    row.appendChild(yes);
    row.appendChild(no);
    panel.appendChild(row);
    return panel;
  }

  function renderVersion(f) {
    var section = node('section');
    section.appendChild(node('h2', null, 'Version'));
    var state = f['upgrade.state'];
    var installed = f['install.present'] === 'yes';
    if (state === 'recovery-needed' || state === 'interrupted') {
      section.appendChild(node('p', 'ls-notice', 'The upgrade needs your attention. It ' +
        (state === 'interrupted' ? 'was interrupted' : 'did not finish') + ' at the step: ' + (f['upgrade.step'] || 'unknown') +
        '. The database may already have been upgraded, so the previous version is not started on its own.'));
      var review = node('button', 'ls-primary', 'Review recovery…');
      review.id = 'restore-review';
      review.type = 'button';
      review.addEventListener('click', function () {
        section.appendChild(confirmPanel(
          'Lockstep will: stop the service, restore the database backup taken before the upgrade, put the previous version back and start it.',
          'restore-previous', 'Restore now',
          function () { runInstall('restore-previous', 'recovery-' + f['upgrade.id'], 'Done: the previous version is back.'); }));
      });
      lifecycleButtons.push(review);
      section.appendChild(review);
      return section;
    }
    if (f['candidate.present'] === 'yes') {
      var pending = f['candidate.pending'];
      var upgrades = pending === '0' ? 'It needs no database upgrades.'
        : pending === '1' ? 'It applies 1 database upgrade.'
          : /^[0-9]+$/.test(pending || '') ? 'It applies ' + pending + ' database upgrades.' : '';
      var commit = (f['candidate.commit'] || '').slice(0, 7);
      section.appendChild(node('p', null, 'A new version is ready to install: version ' + commit + '. ' + upgrades));
      var plan = installed
        ? 'Lockstep will: back up the database and check the backup, stop the service, upgrade the database, start the new version and check that it works.'
        : 'Lockstep will: set up the database, start Lockstep and check that it works.';
      var applyReview = node('button', 'ls-primary', installed ? 'Review and upgrade…' : 'Review and install…');
      applyReview.id = 'apply-review';
      applyReview.type = 'button';
      applyReview.addEventListener('click', function () {
        section.appendChild(confirmPanel(plan, 'apply-candidate', installed ? 'Upgrade now' : 'Install now', function () {
          runInstall('apply-candidate', 'candidate-' + f['candidate.digest'], installed ? 'Done: Lockstep was upgraded.' : 'Done: Lockstep was installed.');
        }));
      });
      lifecycleButtons.push(applyReview);
      var row = node('div', 'ls-actions');
      row.appendChild(applyReview);
      var again = node('button', null, 'Prepare again');
      again.id = 'prepare-candidate';
      again.type = 'button';
      again.addEventListener('click', function () {
        runInstall('prepare-candidate', 'candidate-' + f['candidate.digest'], 'Done: the new version was prepared again.');
      });
      lifecycleButtons.push(again);
      row.appendChild(again);
      section.appendChild(row);
      return section;
    }
    section.appendChild(node('p', null, installed
      ? 'To install a newer version from this computer’s copy of Lockstep, prepare it first. Preparing builds it and changes nothing yet.'
      : 'Lockstep is not installed yet. Prepare it first: this builds it from this computer’s copy and changes nothing yet.'));
    var prepare = node('button', 'ls-primary', installed ? 'Prepare an update' : 'Prepare Lockstep');
    prepare.id = 'prepare-candidate';
    prepare.type = 'button';
    prepare.addEventListener('click', function () { runInstall('prepare-candidate', 'candidate-none', 'Done: the new version is ready to review.'); });
    lifecycleButtons.push(prepare);
    section.appendChild(prepare);
    return section;
  }

  function renderStatus(result) {
    var f = result.fields || {};
    lifecycleButtons = [];
    clear();
    heading();
    showNotice();
    if (afterNotice) {
      app.appendChild(node('p', 'ls-notice', afterNotice));
      afterNotice = null;
    }
    if (f['service.state'] === 'running' && f['service.health'] === 'answers') {
      var openRow = node('div', 'ls-actions');
      var open = node('button', 'ls-primary', 'Open Lockstep');
      open.id = 'open-application';
      open.type = 'button';
      open.addEventListener('click', openApplication);
      lifecycleButtons.push(open);
      openRow.appendChild(open);
      app.appendChild(openRow);
    }
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
    var readiness = f['database.readiness'];
    var reason = f['database.reason'];
    var server = f['database.server'];
    var canStart = f['install.present'] === 'yes' && readiness === 'ready';
    var startWhy = canStart ? null : 'It can start once the application is installed and the database is ready.';
    if (service === 'running') {
      var health = f['service.health'] === 'answers' ? null : 'It is running but does not answer yet.';
      item(list, 'Service', 'Running', health, !health, [
        lifecycleButton('service-stop', 'Stop', true),
        lifecycleButton('service-restart', 'Restart', canStart)
      ]);
    } else if (service === 'stopped') {
      var exitCode = f['service.exitcode'] && f['service.exitcode'] !== 'none' && f['service.exitcode'] !== 'unknown' ? 'It last stopped with exit code ' + f['service.exitcode'] + '.' : null;
      item(list, 'Service', 'Not running', startWhy || exitCode, false, [lifecycleButton('service-start', 'Start', canStart)]);
    } else if (service === 'absent') {
      item(list, 'Service', 'Not running', startWhy || 'It has not been started yet.', false, [lifecycleButton('service-start', 'Start', canStart)]);
    } else {
      item(list, 'Service', 'Unknown', null, false);
    }

    var dbButtons = [];
    if (server === 'running') {
      dbButtons.push(lifecycleButton('database-stop', 'Stop', service !== 'running'));
    } else if (server === 'stopped' || server === 'absent') {
      dbButtons.push(lifecycleButton('database-start', 'Start', true));
    }
    var dbStopWhy = server === 'running' && service === 'running' ? 'To stop the database, stop the service first.' : null;
    if (readiness === 'ready') {
      item(list, 'Database', 'Ready', dbStopWhy, true, dbButtons);
    } else if (readiness === 'not-ready') {
      item(list, 'Database', 'Not ready', DATABASE_REASONS[reason] || 'the database is not ready', false, dbButtons);
    } else if (reason === 'not-installed') {
      item(list, 'Database', 'Unknown', 'Lockstep is not installed yet, so the database was not checked.', false, dbButtons);
    } else {
      item(list, 'Database', 'Unknown', null, false, dbButtons);
    }

    if (f['docker.server'] && f['docker.server'] !== 'unknown') {
      item(list, 'Docker', 'Available', 'Version ' + f['docker.server'], true);
    } else if (f['docker.server'] === 'unknown') {
      item(list, 'Docker', 'Unknown', 'Lockstep runs its parts in Docker; it could not ask Docker for its version.', false);
    }
    app.appendChild(list);
    if (f['upgrade.state'] !== undefined) { app.appendChild(renderVersion(f)); }
    app.appendChild(renderFolders(service === 'running'));

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
