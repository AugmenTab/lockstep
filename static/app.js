// Lockstep application shell (contract C-P3.4 A1–A7). This script builds the
// frame with textContent only; the sections are server-rendered fragments that
// htmx fetches and swaps into #content (no eval, no script tags, same origin
// only). The session lives only in this origin's localStorage and is sent only
// as the X-Lockstep-Session header, to this service.
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

  // The sign-in token arrives in the fragment of /app/sign-in. Take it, then
  // remove it from the address bar and from this history entry before anything else.
  var token = null;
  if (window.location.pathname === '/app/sign-in' && window.location.hash.length > 1) {
    token = window.location.hash.slice(1);
  }
  var initial = sectionFromPath(window.location.pathname) || 'home';
  window.history.replaceState(null, '', '/app/' + initial);

  function sectionFromPath(path) {
    var match = /^\/app\/([a-z]+)$/.exec(path);
    if (!match) { return null; }
    for (var i = 0; i < SECTIONS.length; i += 1) {
      if (SECTIONS[i][0] === match[1]) { return match[1]; }
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
        go(s[0], true);
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
  }

  function renderUnavailable(section) {
    clear(content);
    content.appendChild(node('h1', null, 'Lockstep is not answering right now'));
    content.appendChild(node('p', null, 'Nothing was changed. If Lockstep was stopped, start it again from the control pane: run lockstep on this computer.'));
    var again = node('button', 'ls-primary', 'Try again');
    again.id = 'try-again';
    again.type = 'button';
    again.addEventListener('click', function () { go(section, false); });
    content.appendChild(again);
  }

  function go(section, push) {
    current = section;
    if (push) { window.history.pushState(null, '', '/app/' + section); }
    Object.keys(links).forEach(function (name) {
      if (name === section) { links[name].setAttribute('aria-current', 'page'); } else { links[name].removeAttribute('aria-current'); }
    });
    clear(content);
    content.appendChild(node('p', 'ls-muted', 'Loading…'));
    return window.htmx.ajax('GET', '/app/fragments/' + section, { target: '#content', swap: 'innerHTML' });
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
    if (event.detail.target === content) {
      var h = content.querySelector('h1');
      document.title = (h ? h.textContent + ' – ' : '') + 'Lockstep';
    }
  });

  window.addEventListener('popstate', function () {
    var section = sectionFromPath(window.location.pathname);
    if (section && content && storedSession()) { go(section, false); }
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
