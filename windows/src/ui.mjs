export const $ = (id) => document.getElementById(id);
export const S = { settings: {}, profiles: [], recents: [], doc: null, id: null, state: null };
export const T = (zh, en) => (S.settings.lang === 'en' ? en : zh);
export const uid = () => crypto.randomUUID();
export function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') node.className = v;
    else if (k.startsWith('on')) node.addEventListener(k.slice(2), guard(v));
    else if (v !== undefined && v !== null) node[k] = v;
  }
  node.append(...children.filter((c) => c !== undefined && c !== null));
  return node;
}
export function guard(fn) {
  return (...args) => {
    try {
      const r = fn(...args);
      if (r?.catch) r.catch(report);
      return r;
    } catch (err) {
      report(err);
    }
  };
}
export function report(error) {
  console.error(error);
  toast(error.message || String(error));
}
let toastTimer;
export function toast(text) {
  const node = $('toast');
  node.textContent = text;
  node.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (node.hidden = true), 4200);
}
export const btn = (text, fn, cls = '') => el('button', { textContent: text, onclick: fn, class: cls });
export const select = (options, value, change) => {
  const n = el('select', { onchange: () => change?.(n.value) });
  for (const [v, t] of options) n.append(el('option', { value: v, textContent: t }));
  n.value = value;
  return n;
};
export const row = (...nodes) => el('div', { class: 'row' }, ...nodes);
export function popup(x, y, ...actions) {
  return showPopup(x, y, false, actions);
}
export function menu(x, y, ...actions) {
  return showPopup(x, y, true, actions);
}
function showPopup(x, y, vertical, actions) {
  const n = $('actionBar');
  n.classList.toggle('menuList', vertical);
  n.replaceChildren(...actions);
  n.hidden = false;
  n.style.left = Math.max(2, Math.min(x, innerWidth - n.offsetWidth - 8)) + 'px';
  n.style.top = Math.max(2, Math.min(y, innerHeight - n.offsetHeight - 6)) + 'px';
}
export function hidePopup() {
  $('actionBar').hidden = true;
}
document.addEventListener('pointerdown', (ev) => {
  if (!ev.target.closest('#actionBar')) hidePopup();
});
$('actionBar').addEventListener('click', (event) => { if (event.target.closest('button')) hidePopup(); });
export function modal(title, ...nodes) {
  const d = el('dialog');
  const close = btn('×', () => d.close());
  d.append(el('div', { class: 'dialogHead' }, el('h2', { textContent: title }), close), ...nodes);
  document.body.append(d);
  d.addEventListener('close', () => d.remove(), { once: true });
  d.showModal();
  return d;
}
export function inputDialog(title, value = '', options = {}) {
  return new Promise((resolve) => {
    const input = el(options.multi ? 'textarea' : 'input', { value });
    if (options.secret) input.type = 'password';
    if (options.multi) input.rows = 5;
    let answer = null;
    const submit = () => {
      answer = input.value;
      d.close();
    };
    const d = modal(
      title,
      el('label', { class: 'field' }, input),
      btn(T('确定', 'OK'), submit, 'primary')
    );
    if (options.multi) d.classList.add('noteDialog');
    d.addEventListener('close', () => resolve(answer), { once: true });
    input.focus();
    input.select();
    input.onkeydown = (e) => {
      if (e.key === 'Enter' && (!options.multi || e.ctrlKey)) {
        e.preventDefault();
        submit();
      }
    };
  });
}
export function icon(name) {
  const i = el('i', { class: 'icon' });
  i.setAttribute('aria-hidden', 'true');
  i.style.setProperty('--icon', 'url(../assets/icons/' + name + '.svg)');
  return i;
}
export function iconButton(name, title, fn) {
  const b = btn('', fn, 'glyph');
  b.setAttribute('aria-label', title);
  b.title = title;
  b.append(icon(name));
  return b;
}
export function localize() {
  document.documentElement.lang = T('zh-CN', 'en');
  for (const node of document.querySelectorAll('[data-label]')) {
    const title = T(...node.dataset.label.split('|'));
    node.textContent = title;
    if (node.dataset.icon) {
      node.setAttribute('aria-label', title);
      node.title = title;
      node.classList.add('glyph');
      node.replaceChildren(icon(node.dataset.icon));
    }
  }
  for (const node of document.querySelectorAll('[data-placeholder]'))
    node.placeholder = T(...node.dataset.placeholder.split('|'));
}
export async function preference(change) {
  Object.assign(S.settings, change);
  await folio.settings(change);
}
let timer,
  pending = Promise.resolve();
export function save() {
  clearTimeout(timer);
  timer = setTimeout(() => flush().catch(report), 120);
}
export async function flush() {
  clearTimeout(timer);
  if (S.id && S.state) {
    const job = folio.savePaper(S.id, S.state);
    pending = job;
    await job;
  } else await pending;
}
export function parsePages(input, count) {
  const pages = new Set();
  for (const term of input
    .replace(/[，、]/g, ',')
    .replace(/[–—]/g, '-')
    .split(',')) {
    const m = /^\s*(\d+)\s*(?:-\s*(\d+)\s*)?$/.exec(term);
    if (!m) throw Error(T('页码格式有误', 'Invalid page range'));
    const start = +m[1],
      end = +(m[2] ?? m[1]);
    if (start < 1 || end < start || end > count) throw Error(T('页码超出范围', 'Page out of range'));
    for (let i = start; i <= end; i++) pages.add(i);
  }
  return [...pages];
}
export const pageLabel = (p) => T('第 ' + p + ' 页', 'Page ' + p);
export function paperState() {
  return {
    page: 1,
    scale: 'page-width',
    continuous: true,
    rotations: {},
    bookmarks: [],
    cards: [],
    dismissed: [],
    chats: [],
    chatId: null,
  };
}
