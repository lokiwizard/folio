import { tagTitle } from './settings.mjs';
import * as pdfjs from '../assets/pdf/build/pdf.mjs';
import {
  S,
  T,
  $,
  el,
  btn,
  icon,
  iconButton,
  select,
  popup,
  hidePopup,
  inputDialog,
  toast,
  uid,
  save,
  flush,
  pageLabel,
  parsePages,
  paperState,
  report,
} from './ui.mjs';
const { EventBus, PDFViewer, PDFLinkService, PDFFindController } =
  await import('../assets/pdf/web/pdf_viewer.mjs');
const assets = new URL('../assets/pdf/', import.meta.url).href;
pdfjs.GlobalWorkerOptions.workerSrc = assets + 'build/pdf.worker.mjs';
export const loadTask = (data) =>
  pdfjs.getDocument({
    data,
    cMapUrl: assets + 'cmaps/',
    cMapPacked: true,
    standardFontDataUrl: assets + 'standard_fonts/',
    wasmUrl: assets + 'wasm/',
    iccUrl: assets + 'iccs/',
    isEvalSupported: false,
    rendererSrc: assets + 'build/pdf.renderer.mjs',
  });
const bus = new EventBus(),
  links = new PDFLinkService({ eventBus: bus });
const find = new PDFFindController({ eventBus: bus, linkService: links });
export const view = new PDFViewer({
  container: $('viewerContainer'),
  viewer: $('viewer'),
  eventBus: bus,
  linkService: links,
  findController: find,
  annotationMode: pdfjs.AnnotationMode.DISABLE,
  enablePermissions: true,
  enableAutoLinking: false,
  removePageBorders: true,
});
links.setViewer(view);
let task,
  password = '',
  restoring = false,
  opening = false,
  navMode = 'pages',
  thumbObserver,
  sourceLinks = new Map(),
  history = [],
  clipMode = false,
  marquee = null;
export const hooks = {
  opened: () => {},
  closing: () => {},
  cards: () => {},
  quote: () => {},
  clipboard: () => {},
  shell: () => {},
};
export function canCopy() {
  return S.copy !== false;
}
export function requireCopy() {
  if (!canCopy()) throw Error(T('此 PDF 限制复制内容', 'Copying is restricted for this PDF'));
}
export const current = () => view.currentPageNumber;
const norm = ([x, y, X, Y]) => [Math.min(x, X), Math.min(y, Y), Math.max(x, X), Math.max(y, Y)];
// Keep non-highlight PDF artwork (such as third-party underlines) in the reading
// canvas. Folio draws editable highlights separately from the immutable source.
function installDisplayFilter(doc) {
  const original = doc.getPage.bind(doc),
    configured = new WeakSet();
  doc.getPage = async (n) => {
    const p = await original(n);
    const annotations = await p.getAnnotations();
    if (configured.has(p)) return p;
    configured.add(p);
    const ids = new Set(annotations.filter((a) => a.subtype === 'Highlight').map((a) => a.id));
    const render = p.render.bind(p);
    p.render = (options) => {
      // Folio explicitly requests raw page content for crops and AI references.
      if (!options.optionalContentConfigPromise && !options.folioDisplay) return render(options);
      let inside = false;
      const filter = (i, ops) => {
        if (ops.fnArray[i] === pdfjs.OPS.beginAnnotation) inside = ids.has(ops.argsArray[i][0]);
        const include = !inside;
        if (ops.fnArray[i] === pdfjs.OPS.endAnnotation) inside = false;
        return include;
      };
      return render({
        ...options,
        annotationMode: pdfjs.AnnotationMode.ENABLE,
        operationsFilter: filter,
      });
    };
    return p;
  };
}
export async function closePaper() {
  if (!S.doc) return;
  hooks.closing();
  await flush();
  restoring = true;
  S.doc = null;
  S.id = null;
  S.state = null;
  sourceLinks.clear();
  history = [];
  thumbObserver?.disconnect();
  view.setDocument(null);
  links.setDocument(null);
  find.setDocument(null);
  await task?.destroy();
  task = null;
  password = '';
  restoring = false;
  clipMode = false;
  $('viewer').classList.remove('clipMode');
  hidePopup();
  $('clip').classList.remove('active');
  hooks.shell();
}
export async function openPaper(get) {
  if (opening) return;
  opening = true;
  let nextTask;
  try {
    const record = await get();
    if (!record) return;
    if (record.id === S.id) {
      hooks.shell();
      return;
    }
    nextTask = loadTask(record.bytes);
    let pass = '';
    nextTask.onPassword = async (update, reason) => {
      const p = await inputDialog(
        reason === 2
          ? T('密码不正确，请重试', 'Incorrect password, try again')
          : T('文档密码', 'Document password'),
        '',
        { secret: true }
      );
      if (p === null) update(new Error(T('已取消', 'Cancelled')));
      else {
        pass = p;
        update(p);
      }
    };
    const doc = await nextTask.promise;
    installDisplayFilter(doc);
    const perms = await doc.getPermissions();
    await closePaper();
    task = nextTask;
    nextTask = null;
    password = pass;
    S.doc = doc;
    S.id = record.id;
    S.name = record.name;
    S.state = { ...paperState(), ...record.state };
    S.copy = !perms || perms.has(pdfjs.PermissionFlag.COPY);
    S.print =
      !perms ||
      perms.has(pdfjs.PermissionFlag.PRINT) ||
      perms.has(pdfjs.PermissionFlag.PRINT_HIGH_QUALITY);
    restoring = true;
    hooks.shell();
    const loaded = new Promise((resolve) => bus.on('pagesinit', resolve, { once: true }));
    links.setDocument(doc);
    view.setDocument(doc);
    await loaded;
    const state = S.state;
    for (const c of state.cards)
      if (c.tag && !S.settings.tags.some((t) => t.id === c.tag)) c.tag = S.settings.defaultTag;
    view.scrollMode = state.continuous ? 0 : 3;
    view.currentScaleValue = String(state.scale || 'page-width');
    for (const [n, rot] of Object.entries(state.rotations))
      view.getPageView(Number(n) - 1)?.update({ rotation: rot });
    go(state.page || 1, state.point);
    view.update();
    restoring = false;
    $('pageCount').textContent = '/ ' + doc.numPages;
    $('page').max = doc.numPages;
    $('page').value = current();
    history = [];
    sourceLinks = new Map();
    hooks.opened();
    await folio.paper(S.id, S.doc.numPages);
    await navigation(navMode);
    importMarks(doc).catch(report);
  } finally {
    opening = false;
    if (nextTask) await nextTask.destroy();
  }
}
function getLocation() {
  const loc = view._location;
  return loc ? { page: loc.pageNumber, point: [loc.left, loc.top] } : { page: current() };
}
bus.on('updateviewarea', ({ location }) => {
  if (!S.state || restoring) return;
  S.state.page = location.pageNumber;
  S.state.point = [location.left, location.top];
  $('page').value = current();
  save();
});
bus.on('scalechanging', ({ scale, presetValue }) => {
  if (!S.state) return;
  const value = presetValue || String(scale);
  if (!restoring) {
    S.state.scale = value;
    save();
  }
  zoomOptions(value);
});
bus.on('pagechanging', ({ pageNumber }) => {
  $('page').value = pageNumber;
  for (const b of $('navList').querySelectorAll('.thumbnail'))
    b.classList.toggle('current', Number(b.dataset.page) === pageNumber);
  revealCurrentThumb();
});
bus.on('pagerendered', ({ pageNumber }) => marks(pageNumber));
bus.on('updatefindmatchescount', ({ matchesCount: c }) => {
  $('matches').textContent = c.current + ' / ' + c.total;
});
bus.on('updatefindcontrolstate', ({ matchesCount: c }) => {
  if (c) $('matches').textContent = c.current + ' / ' + c.total;
});
export function zoomOptions(value = view.currentScaleValue || 'page-width') {
  const list = [
    ['page-width', T('页宽', 'Fit width')],
    ['page-fit', T('整页', 'Fit page')],
    ...['0.5', '0.75', '1', '1.25', '1.5', '2', '3'].map((s) => [s, Math.round(+s * 100) + '%']),
  ];
  if (!list.some((x) => x[0] === value)) list.push([value, Math.round(Number(value) * 100) + '%']);
  list.push(['custom', T('指定比例…', 'Custom zoom…')]);
  $('zoom').replaceChildren(...list.map(([v, t]) => el('option', { value: v, textContent: t })));
  $('zoom').value = value;
}
export function go(page, point, record = false) {
  if (!S.doc) return;
  if (record) history.push(getLocation());
  page = Math.max(1, Math.min(S.doc.numPages, Number(page) || 1));
  view.scrollPageIntoView({
    pageNumber: page,
    destArray: point ? [null, { name: 'XYZ' }, point[0], point[1], null] : undefined,
    ignoreDestinationZoom: true,
  });
}
export function back() {
  const loc = history.pop();
  if (loc) go(loc.page, loc.point);
}
export function rotate() {
  const p = current(),
    v = view.getPageView(p - 1);
  S.state.rotations[p] = ((S.state.rotations[p] || 0) + 90) % 360;
  v.update({ rotation: S.state.rotations[p] });
  view.update();
  save();
  refreshMarks();
  hooks.rotated?.();
}
export function mode() {
  S.state.continuous = !S.state.continuous;
  view.scrollMode = S.state.continuous ? 0 : 3;
  updateMode();
  save();
}
export function updateMode() {
  $('display').classList.toggle('active', S.state?.continuous === false);
}
export function search(again = false, prev = false) {
  bus.dispatch('find', {
    source: window,
    type: again ? 'again' : '',
    query: $('query').value,
    caseSensitive: false,
    entireWord: false,
    highlightAll: true,
    findPrevious: prev,
    matchDiacritics: false,
  });
}
export function showFind(show = true) {
  $('findBar').hidden = !show;
  if (show) {
    $('query').focus();
    $('query').select();
  } else bus.dispatch('findbarclose', {});
}
export function zoomBy(f) {
  view.currentScale = Math.max(0.08, Math.min(8, view.currentScale * f));
}
export async function bookmark() {
  const loc = getLocation(),
    name = await inputDialog(T('书签名称', 'Bookmark name'), pageLabel(loc.page));
  if (name === null) return;
  S.state.bookmarks.push({ ...loc, id: uid(), name });
  save();
  hooks.openNav?.();
  await navigation('bookmarks');
}
export function revealCurrentThumb() {
  if (navMode === 'pages' && !$('navigation').hidden)
    $('navList').querySelector('.thumbnail.current')?.scrollIntoView({ block: 'nearest' });
}
export async function navigation(mode = navMode) {
  navMode = mode;
  thumbObserver?.disconnect();
  const doc = S.doc;
  if (!doc) return;
  const list = $('navList');
  list.replaceChildren();
  list.dataset.mode = mode;
  const tabs = [
    ['pages', T('页面', 'Pages')],
    ['outline', T('目录', 'Outline')],
    ['bookmarks', T('书签', 'Marks')],
  ];
  $('navTabs').replaceChildren(
    ...tabs.map(([v, t]) => {
      const b = btn(t, () => navigation(v), v === mode ? 'active' : '');
      b.setAttribute('aria-label', t);
      b.setAttribute('aria-pressed', String(v === mode));
      b.title = t;
      b.replaceChildren(
        icon({ pages: 'gallery-vertical-end', outline: 'list-tree', bookmarks: 'bookmark' }[v]),
        el('span', { textContent: t })
      );
      return b;
    })
  );
  if (mode === 'bookmarks') {
    for (const mark of S.state.bookmarks) {
      const jump = btn('', () => go(mark.page, mark.point, true), 'markJump');
      jump.append(
        icon('bookmark'),
        el(
          'span',
          {},
          el('strong', { textContent: mark.name }),
          el('small', { textContent: pageLabel(mark.page) })
        )
      );
      const item = el(
        'div',
        { class: 'bookmarkRow' },
        jump,
        iconButton('pencil', T('重命名', 'Rename'), async () => {
          const value = await inputDialog(T('重命名', 'Rename'), mark.name);
          if (value === null) return;
          mark.name = value;
          save();
          navigation(mode);
        }),
        iconButton('trash-2', T('删除书签', 'Delete bookmark'), () => {
          S.state.bookmarks = S.state.bookmarks.filter((m) => m !== mark);
          save();
          navigation(mode);
        })
      );
      list.append(item);
    }
    if (!S.state.bookmarks.length)
      list.append(
        el(
          'div',
          { class: 'navEmpty' },
          icon('book-marked'),
          el('strong', { textContent: T('还没有书签', 'No bookmarks yet') }),
          el('span', {
            textContent: T(
              '按 Ctrl+D，或在「更多」中选择「添加书签」。',
              'Press Ctrl+D or choose Add bookmark from More.'
            ),
          })
        )
      );
  } else if (mode === 'outline') {
    const tree = await doc.getOutline();
    if (doc !== S.doc || mode !== navMode) return;
    function add(parent, items, depth) {
      for (const item of items || []) {
        const children = el('div', { class: 'outlineChildren', hidden: true });
        const expand = () => {
          children.hidden = !children.hidden;
          disclosure.replaceChildren(icon(children.hidden ? 'chevron-right' : 'chevron-down'));
          disclosure.setAttribute('aria-expanded', String(!children.hidden));
        };
        const disclosure = iconButton('chevron-right', T('展开或折叠章节', 'Toggle section'), expand);
        disclosure.setAttribute('aria-expanded', 'false');
        const jump = btn(
          item.title,
          async () => {
            if (item.dest) {
              history.push(getLocation());
              await links.goToDestination(item.dest);
              list.querySelector('.outlineItem.current')?.classList.remove('current');
              itemRow.classList.add('current');
            } else if (item.items?.length) expand();
          },
          'outlineJump'
        );
        const itemRow = el(
          'div',
          { class: 'outlineItem' },
          item.items?.length ? disclosure : icon('file-text'),
          jump
        );
        itemRow.style.paddingInlineStart = Math.min(depth, 5) * 10 + 4 + 'px';
        const group = el('div', { class: depth === 0 ? 'outlineRoot' : '' }, itemRow);
        parent.append(group);
        if (item.items?.length) {
          group.append(children);
          add(children, item.items, depth + 1);
        }
      }
    }
    add(list, tree, 0);
    if (!tree?.length)
      list.append(
        el(
          'div',
          { class: 'navEmpty' },
          icon('list-tree'),
          el('strong', { textContent: T('此 PDF 没有目录', 'This PDF has no outline') })
        )
      );
  } else {
    thumbObserver = new IntersectionObserver(
      (entries) => {
        for (const e of entries) {
          if (!e.isIntersecting) continue;
          thumbObserver.unobserve(e.target);
          const p = Number(e.target.dataset.page);
          renderCrop(doc, p, null, 180, S.state.rotations[p], true)
            .then((c) => {
              if (e.target.isConnected)
                e.target.firstChild.replaceChildren(el('img', { src: c.toDataURL(), alt: '' }));
            })
            .catch(() => {});
        }
      },
      { root: list, rootMargin: '100px' }
    );
    for (let p = 1; p <= doc.numPages; p++) {
      const b = btn(pageLabel(p), () => go(p, null, true), 'thumbnail');
      b.replaceChildren(
        el('span', { class: 'thumbPaper' }),
        el('span', { class: 'thumbCaption', textContent: pageLabel(p) })
      );
      b.classList.toggle('current', p === current());
      b.dataset.page = p;
      list.append(b);
      thumbObserver.observe(b);
    }
    revealCurrentThumb();
  }
}
function viewportRect(v, [x, y, X, Y]) {
  return norm([...v.convertToViewportPoint(x, y), ...v.convertToViewportPoint(X, Y)]);
}
export async function renderCrop(doc, num, rect, maxEdge = 1800, rotation = 0, display = false) {
  const page = await doc.getPage(num),
    angle = (page.rotate + rotation) % 360,
    unit = page.getViewport({ scale: 1, rotation: angle });
  const box = viewportRect(unit, rect ?? page.view),
    w = Math.max(1, box[2] - box[0]),
    h = Math.max(1, box[3] - box[1]),
    scale = Math.min(maxEdge / Math.max(w, h), 4);
  const canvas = el('canvas', {
    width: Math.max(1, Math.ceil(w * scale)),
    height: Math.max(1, Math.ceil(h * scale)),
  });
  await page.render({
    canvas,
    viewport: page.getViewport({ scale, rotation: angle }),
    transform: [1, 0, 0, 1, -box[0] * scale, -box[1] * scale],
    annotationMode: pdfjs.AnnotationMode.DISABLE,
    folioDisplay: display,
  }).promise;
  if (display && doc === S.doc) {
    const ctx = canvas.getContext('2d');
    ctx.globalCompositeOperation = 'multiply';
    ctx.globalAlpha = 0.42;
    for (const card of S.state.cards.filter((c) => c.kind === 'note')) {
      ctx.fillStyle = highlightColor(card);
      for (const anchor of card.anchors.filter((a) => a.page === num)) {
        const [l, b, r, t] = viewportRect(unit, anchor.rect);
        ctx.fillRect((l - box[0]) * scale, (b - box[1]) * scale, (r - l) * scale, (t - b) * scale);
      }
    }
    ctx.globalAlpha = 1;
    ctx.globalCompositeOperation = 'source-over';
  }
  return canvas;
}
function rectForView(v, r) {
  const pos = v.div.getBoundingClientRect(),
    vp = v.viewport;
  const convert = (x, y) =>
    vp.convertToPdfPoint(
      ((x - pos.left) * vp.width) / pos.width,
      ((y - pos.top) * vp.height) / pos.height
    );
  return norm([...convert(r.left, r.top), ...convert(r.right, r.bottom)]);
}
function addCard(data) {
  const card = { id: uid(), title: '', note: '', scale: 1, collapsed: false, ...data };
  S.state.cards.push(card);
  save();
  refreshMarks();
  hooks.cards(card.kind);
  return card;
}
export function makeNote(text, anchors, tag = S.settings.defaultTag, note = '') {
  return addCard({ kind: 'note', text, anchors, tag, note });
}
function selection(ev) {
  if (!S.doc || !canCopy() || clipMode) return;
  const sel = getSelection();
  if (!sel?.rangeCount || sel.isCollapsed || !$('viewer').contains(sel.anchorNode)) return;
  const range = sel.getRangeAt(0),
    text = sel.toString().trim();
  if (!text) return;
  const anchors = [];
  for (const page of $('viewer').querySelectorAll('.page')) {
    const layer = page.querySelector('.textLayer');
    if (!layer || !range.intersectsNode(layer)) continue;
    const n = Number(page.dataset.pageNumber),
      v = view.getPageView(n - 1);
    const walker = document.createTreeWalker(layer, NodeFilter.SHOW_TEXT);
    while (walker.nextNode()) {
      const node = walker.currentNode;
      if (!node.length || !range.intersectsNode(node)) continue;
      const part = new Range();
      part.selectNodeContents(node);
      if (node === range.startContainer) part.setStart(node, range.startOffset);
      if (node === range.endContainer) part.setEnd(node, range.endOffset);
      for (const r of part.getClientRects())
        if (r.width > 0.5 && r.height > 0.5) anchors.push({ page: n, rect: rectForView(v, r) });
    }
  }
  if (!anchors.length) return;
  const commit = (tag, note = '') => {
    makeNote(text, anchors, tag, note);
    sel.removeAllRanges();
    hidePopup();
  };
  popup(
    ev.clientX,
    ev.clientY + 8,
    select(
      [['', T('高亮…', 'Highlight…')], ...S.settings.tags.map((t) => [t.id, tagTitle(t)])],
      '',
      (id) => {
        if (id) commit(id);
      }
    ),
    btn(T('默认高亮', 'Highlight'), () => commit(S.settings.defaultTag)),
    btn(T('笔记', 'Note'), async () => {
      const note = await inputDialog(T('添加备注', 'Add note'), '', { multi: true });
      if (note !== null) commit(null, note);
    }),
    btn(T('问 AI', 'Ask AI'), () => hooks.quote({ kind: 'note', text, anchors, title: '' }))
  );
}
$('viewer').addEventListener('pointerup', (e) => setTimeout(() => selection(e), 0));
export function toggleClip() {
  requireCopy();
  clipMode = !clipMode;
  $('clip').classList.toggle('active', clipMode);
  $('viewer').classList.toggle('clipMode', clipMode);
}
$('viewer').addEventListener(
  'pointerdown',
  (e) => {
    const page = e.target.closest('.page');
    if (!clipMode || !page || e.button !== 0) return;
    e.preventDefault();
    getSelection().removeAllRanges();
    const n = Number(page.dataset.pageNumber),
      v = view.getPageView(n - 1),
      bounds = page.getBoundingClientRect(),
      x = e.clientX,
      y = e.clientY;
    const box = el('div', { class: 'marquee' });
    document.body.append(box);
    marquee = box;
    const geom = (ev) => {
      const xx = Math.max(bounds.left, Math.min(bounds.right, ev.clientX)),
        yy = Math.max(bounds.top, Math.min(bounds.bottom, ev.clientY));
      return new DOMRect(Math.min(x, xx), Math.min(y, yy), Math.abs(xx - x), Math.abs(yy - y));
    };
    const move = (ev) => {
      const r = geom(ev);
      Object.assign(box.style, {
        left: r.x + 'px',
        top: r.y + 'px',
        width: r.width + 'px',
        height: r.height + 'px',
      });
    };
    const cleanup = () => {
      box.remove();
      marquee = null;
      window.removeEventListener('pointermove', move);
      window.removeEventListener('pointerup', up);
      window.removeEventListener('pointercancel', cleanup);
    };
    const up = (ev) => {
      const r = geom(ev);
      cleanup();
      if (r.width < 3 || r.height < 3 || !clipMode) return;
      const anchor = { page: n, rect: rectForView(v, r) };
      toggleClip();
      popup(
        ev.clientX,
        ev.clientY,
        btn(T('固定', 'Pin'), () =>
          addCard({ kind: 'pin', anchors: [anchor], rotation: S.state.rotations[n] || 0, drawing: null })
        ),
        btn(T('复制图片', 'Copy image'), async () =>
          folio.copyImage(
            (await renderCrop(S.doc, n, anchor.rect, 2200, S.state.rotations[n])).toDataURL()
          )
        ),
        btn(T('问 AI', 'Ask AI'), () =>
          hooks.quote({ kind: 'pin', anchors: [anchor], rotation: S.state.rotations[n] || 0 })
        )
      );
    };
    window.addEventListener('pointermove', move);
    window.addEventListener('pointerup', up);
    window.addEventListener('pointercancel', cleanup);
    move(e);
  },
  true
);
function position(div, rect, v) {
  const [x, y, X, Y] = viewportRect(v.viewport, rect);
  Object.assign(div.style, {
    left: (x / v.viewport.width) * 100 + '%',
    top: (y / v.viewport.height) * 100 + '%',
    width: ((X - x) / v.viewport.width) * 100 + '%',
    height: ((Y - y) / v.viewport.height) * 100 + '%',
  });
}
function highlightColor(card) {
  const tag = S.settings.tags.find((t) => t.id === card.tag);
  if (card.sourceColor && !tag?.override && !card.recolored) return card.sourceColor;
  return tag?.color || '#ecc54d';
}
export function marks(n) {
  if (!S.doc) return;
  const v = view.getPageView(n - 1);
  if (!v?.div || !v.pdfPage) return;
  v.div.querySelector('.folioMarks')?.remove();
  const layer = el('div', { class: 'folioMarks' });
  v.div.append(layer);
  for (const a of sourceLinks.get(n) || []) {
    const hit = el('a', {
      href: '#',
      title: a.title || '',
      onclick: async (e) => {
        e.preventDefault();
        if (a.dest) {
          history.push(getLocation());
          await links.goToDestination(a.dest);
        } else if (a.url) {
          await folio.external(a.url);
        }
      },
    });
    hit.style.position = 'absolute';
    hit.style.pointerEvents = 'auto';
    position(hit, a.rect, v);
    layer.append(hit);
  }
  for (const card of S.state.cards) {
    if (card.kind !== 'note') continue;
    for (const a of card.anchors) {
      if (a.page !== n) continue;
      const mark = el('span', { class: 'folioMark', title: card.title || card.text });
      position(mark, a.rect, v);
      mark.style.backgroundColor = highlightColor(card);
      mark.onpointerdown = (e) => {
        if (!clipMode) e.stopPropagation();
      };
      mark.onclick = (e) => {
        if (!clipMode)
          popup(
            e.clientX,
            e.clientY,
            btn(T('取消高亮', 'Remove highlight'), () => hooks.remove(card)),
            btn(T('查看批注', 'Show note'), () => hooks.cards('note', card.id))
          );
      };
      layer.append(mark);
    }
  }
}
export function refreshMarks() {
  if (navMode === 'pages' && !$('navigation').hidden) navigation('pages').catch(report);
  for (const p of $('viewer').querySelectorAll('.page[data-loaded]')) marks(+p.dataset.pageNumber);
}
async function importMarks(doc) {
  for (let n = 1; n <= doc.numPages; n++) {
    if (doc !== S.doc) return;
    const page = await doc.getPage(n),
      ann = await page.getAnnotations();
    if (doc !== S.doc) return;
    sourceLinks.set(
      n,
      ann.filter((a) => a.subtype === 'Link' && (a.dest || a.url))
    );
    const items = ann.filter((a) => a.subtype === 'Highlight');
    let text;
    for (const a of items) {
      const key = n + '/' + a.id;
      if (S.state.dismissed.includes(key) || S.state.cards.some((c) => c.source === key)) continue;
      const anchors = [];
      const quads = a.quadPoints ?? [];
      for (let i = 0; i + 7 < quads.length; i += 8) {
        const xx = [quads[i], quads[i + 2], quads[i + 4], quads[i + 6]],
          yy = [quads[i + 1], quads[i + 3], quads[i + 5], quads[i + 7]];
        anchors.push({
          page: n,
          rect: [Math.min(...xx), Math.min(...yy), Math.max(...xx), Math.max(...yy)],
        });
      }
      if (!anchors.length) anchors.push({ page: n, rect: a.rect });
      text ??= S.copy ? await page.getTextContent() : { items: [] };
      if (doc !== S.doc) return;
      const extract = anchors
        .map(({ rect: [l, b, r, t] }) =>
          text.items
            .filter((i) => i.str)
            .map((i) => {
              const x = i.transform[4],
                y = i.transform[5],
                h = i.height || 10;
              if (y + h * 0.5 < b || y + h * 0.5 > t || x + i.width <= l || x >= r) return '';
              const chars = Array.from(i.str),
                step = i.width / Math.max(1, chars.length);
              return chars
                .filter((_, j) => x + step * (j + 0.5) >= l && x + step * (j + 0.5) <= r)
                .join('');
            })
            .filter(Boolean)
            .join(' ')
            .trim()
        )
        .filter(Boolean)
        .join('\n');
      S.state.cards.push({
        id: uid(),
        kind: 'note',
        source: key,
        sourceColor: a.color ? 'rgb(' + Array.from(a.color).join(',') + ')' : null,
        text: extract,
        title: '',
        note: a.contentsObj?.str || '',
        scale: 1,
        tag: S.settings.defaultTag,
        anchors,
      });
      save();
    }
    if (doc !== S.doc) return;
    marks(n);
    if (items.length) hooks.changed?.();
    if (n % 10 === 0) await new Promise((r) => setTimeout(r, 0));
  }
}
export async function printPaper(single) {
  if (!S.print) throw Error(T('此 PDF 限制打印', 'Printing is restricted'));
  const doc = S.doc,
    area = $('printPages');
  area.replaceChildren();
  try {
    for (const n of single ? [current()] : Array.from({ length: doc.numPages }, (_, i) => i + 1)) {
      const c = await renderCrop(doc, n, null, 1800, S.state.rotations[n], true);
      const img = el('img', { src: c.toDataURL('image/jpeg', 0.92) });
      await img.decode();
      area.append(img);
    }
    await folio.print();
  } finally {
    area.replaceChildren();
  }
}
export async function extract() {
  requireCopy();
  const spec = await inputDialog(
    T('提取页码，例如 5, 1–3', 'Extract pages, e.g. 5, 1–3'),
    String(current())
  );
  if (spec === null) return;
  const id = S.id,
    range = parsePages(spec, S.doc.numPages).join(','),
    bytes = await folio.read(id),
    worker = new Worker(new URL('./qpdf-worker.js', import.meta.url));
  try {
    const wasm = await (await fetch(new URL('../assets/qpdf/qpdf.wasm', import.meta.url))).arrayBuffer();
    const out = await new Promise((resolve, reject) => {
      worker.onmessage = ({ data }) => (data.error ? reject(Error(data.error)) : resolve(data.out));
      worker.onerror = (e) => reject(Error(e.message));
      worker.postMessage({ bytes, password, range, wasm }, [wasm]);
    });
    const verify = loadTask(out.slice());
    try {
      const doc = await verify.promise;
      if (doc.numPages !== range.split(',').length) throw Error('Page count mismatch');
    } finally {
      await verify.destroy();
    }
    await folio.extract(id, out);
  } finally {
    worker.terminate();
  }
}
