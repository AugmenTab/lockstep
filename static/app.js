// Lockstep application shell (contract C-P3.4 A1–A7, C-P3.5 J9, C-P3.7 L7, C-P3.8 M6). This script
// builds the frame with textContent only; the sections are server-rendered
// fragments that htmx fetches and swaps into #content (no eval, no script tags,
// same origin only). The session lives only in this origin's localStorage and is
// sent only as the X-Lockstep-Session header, to this service.
(function () {
  'use strict';

  var KEY = 'lockstep.app.session';
  var app = document.getElementById('app');
  var SECTIONS = [
    ['home', 'Home'],
    ['projects', 'Projects'],
    ['tasks', 'Tasks'],
    ['decisions', 'Decisions'],
    ['activity', 'Activity'],
    ['settings', 'Settings'],
    ['advanced', 'Advanced']
  ];
  var UUID = '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})';
  var PROJECT = new RegExp('^/app/projects/' + UUID + '$');
  var NEW_TASK = new RegExp('^/app/projects/' + UUID + '/tasks/new$');
  var TASK = new RegExp('^/app/tasks/' + UUID + '$');
  var CHECKS = new RegExp('^/app/projects/' + UUID + '/checks$');
  var DECISION = new RegExp('^/app/decisions/' + UUID + '$');
  var FORM_ACTION = new RegExp('^/app/api/(projects|projects/' + UUID + '/(connect|tasks|checks)|tasks/' + UUID + '/(edit|decide)|decisions/' + UUID + ')$');

  // The sign-in token arrives in the fragment of /app/sign-in. Take it, then
  // remove it from the address bar and from this history entry before anything else.
  var token = null;
  if (window.location.pathname === '/app/sign-in' && window.location.hash.length > 1) {
    token = window.location.hash.slice(1);
  }
  var initial = routeFor(window.location.pathname) ? window.location.pathname : '/app/home';
  window.history.replaceState(null, '', initial);

  // The fragment for a page address, and the section it belongs to; null for anything else.
  function routeFor(path) {
    if (path === '/app/projects/new') { return { fragment: '/app/fragments/project-new', section: 'projects' }; }
    var project = PROJECT.exec(path);
    if (project) { return { fragment: '/app/fragments/project/' + project[1], section: 'projects' }; }
    var newTask = NEW_TASK.exec(path);
    if (newTask) { return { fragment: '/app/fragments/task-new/' + newTask[1], section: 'projects' }; }
    var task = TASK.exec(path);
    if (task) { return { fragment: '/app/fragments/task/' + task[1], section: 'tasks' }; }
    var checks = CHECKS.exec(path);
    if (checks) { return { fragment: '/app/fragments/project-checks/' + checks[1], section: 'projects' }; }
    var decision = DECISION.exec(path);
    if (decision) { return { fragment: '/app/fragments/decision/' + decision[1], section: 'decisions' }; }
    var match = /^\/app\/([a-z]+)$/.exec(path);
    if (!match) { return null; }
    for (var i = 0; i < SECTIONS.length; i += 1) {
      if (SECTIONS[i][0] === match[1]) { return { fragment: '/app/fragments/' + match[1], section: match[1] }; }
    }
    return null;
  }

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
  function clear(element) {
    while (element.firstChild) { element.removeChild(element.firstChild); }
  }

  var notice = null;

  function renderSignedOut() {
    clear(app);
    var main = node('main', 'ls-app-main');
    main.appendChild(node('h1', null, 'Lockstep'));
    if (notice) { main.appendChild(node('p', 'ls-notice', notice)); }
    main.appendChild(node('p', null, 'You are signed out. To open Lockstep, run lockstep and press Open Lockstep.'));
    app.appendChild(main);
  }

  // Only this script's own requests carry the session, and only to this origin.
  document.body.addEventListener('htmx:configRequest', function (event) {
    var session = storedSession();
    if (session) { event.detail.headers['X-Lockstep-Session'] = session; }
  });

  var content = null;
  var links = {};
  var current = null;

  function renderFrame() {
    clear(app);
    var header = node('header', 'ls-app-header');
    header.appendChild(node('p', 'ls-app-name', 'Lockstep'));
    var nav = node('nav', 'ls-app-nav');
    nav.setAttribute('aria-label', 'Sections');
    SECTIONS.forEach(function (s) {
      var a = node('a', null, s[1]);
      a.href = '/app/' + s[0];
      a.addEventListener('click', function (event) {
        event.preventDefault();
        go('/app/' + s[0], true);
      });
      links[s[0]] = a;
      nav.appendChild(a);
    });
    header.appendChild(nav);
    var out = node('button', null, 'Sign out');
    out.id = 'sign-out';
    out.type = 'button';
    out.addEventListener('click', signOut);
    header.appendChild(out);
    app.appendChild(header);
    content = node('main', 'ls-app-main');
    content.id = 'content';
    content.tabIndex = -1;
    app.appendChild(content);

    // Links to other application pages inside a section stay in this page.
    content.addEventListener('click', function (event) {
      var a = event.target.closest ? event.target.closest('a') : null;
      if (!a || !content.contains(a)) { return; }
      var href = a.getAttribute('href') || '';
      if (routeFor(href)) {
        event.preventDefault();
        go(href, true);
      }
    });
    // Forms inside a section are sent by htmx with the session header; the answer replaces the section.
    content.addEventListener('submit', function (event) {
      var form = event.target;
      if (!form || form.tagName !== 'FORM') { return; }
      var action = form.getAttribute('action') || '';
      if (!FORM_ACTION.test(action)) { return; }
      event.preventDefault();
      // Repeated names (the "depends on" checkboxes) are sent as lists.
      var values = {};
      new window.FormData(form).forEach(function (value, name) {
        if (Object.prototype.hasOwnProperty.call(values, name)) {
          values[name] = [].concat(values[name], value);
        } else {
          values[name] = value;
        }
      });
      Array.prototype.forEach.call(form.querySelectorAll('button'), function (b) { b.disabled = true; });
      window.htmx.ajax('POST', action, { target: '#content', swap: 'innerHTML', values: values });
    });
  }

  function renderUnavailable(path) {
    clear(content);
    content.appendChild(node('h1', null, 'Lockstep is not answering right now'));
    content.appendChild(node('p', null, 'Nothing was changed. If Lockstep was stopped, start it again from the control pane: run lockstep on this computer.'));
    var again = node('button', 'ls-primary', 'Try again');
    again.id = 'try-again';
    again.type = 'button';
    again.addEventListener('click', function () { go(path, false); });
    content.appendChild(again);
  }

  function highlight(section) {
    Object.keys(links).forEach(function (name) {
      if (name === section) { links[name].setAttribute('aria-current', 'page'); } else { links[name].removeAttribute('aria-current'); }
    });
  }

  function go(path, push) {
    var route = routeFor(path);
    if (!route) { return null; }
    current = path;
    if (push) { window.history.pushState(null, '', path); }
    highlight(route.section);
    clear(content);
    content.appendChild(node('p', 'ls-muted', 'Loading…'));
    return window.htmx.ajax('GET', route.fragment, { target: '#content', swap: 'innerHTML' });
  }

  document.body.addEventListener('htmx:responseError', function (event) {
    if (event.detail.xhr && event.detail.xhr.status === 401) {
      forgetSession();
      notice = 'Your sign-in has ended.';
      renderSignedOut();
      return;
    }
    renderUnavailable(current);
  });
  document.body.addEventListener('htmx:sendError', function () { renderUnavailable(current); });
  document.body.addEventListener('htmx:afterSwap', function (event) {
    if (event.detail.target !== content) { return; }
    // An answer that is a project's page says so; the address follows it.
    var path = event.detail.xhr ? event.detail.xhr.getResponseHeader('X-Lockstep-Path') : null;
    if (path && (PROJECT.test(path) || TASK.test(path) || CHECKS.test(path) || DECISION.test(path)) && path !== window.location.pathname) {
      current = path;
      window.history.pushState(null, '', path);
    }
    var h = content.querySelector('h1');
    document.title = (h ? h.textContent + ' – ' : '') + 'Lockstep';
  });

  window.addEventListener('popstate', function () {
    if (routeFor(window.location.pathname) && content && storedSession()) { go(window.location.pathname, false); }
  });

  function signOut() {
    var session = storedSession() || '';
    window.fetch('/app/api/sign-out', {
      method: 'POST',
      headers: { 'X-Lockstep-Session': session, 'Content-Type': 'text/plain' },
      body: '',
      credentials: 'omit',
      cache: 'no-store',
      redirect: 'error'
    }).catch(function () { return null; }).then(function () {
      forgetSession();
      notice = null;
      renderSignedOut();
    });
  }

  async function start() {
    if (token) {
      var sent = token;
      token = null;
      var response = await window.fetch('/app/api/session', {
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
        notice = 'This sign-in link was already used or has expired.';
      }
    }
    if (!storedSession()) { renderSignedOut(); return; }
    renderFrame();
    go(initial, false);
  }

  start().catch(function () {
    if (content) { renderUnavailable(current || initial); } else { renderSignedOut(); }
  });
}());
