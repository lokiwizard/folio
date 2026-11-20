import {
  S,
  T,
  $,
  el,
  btn,
  icon,
  action,
  inputDialog,
  menu,
  popup,
  hidePopup,
  guard,
  report,
  flush,
  save,
  preference,
  pageLabel,
} from './ui.mjs';
import * as reader from './reader.mjs';
import { cardHooks, showCards, removeCard, exportNotes, resetCards } from './cards.mjs';
import { chatHooks, showChat, addReference, openComposer, resetChat, setupChat } from './chat.mjs';
import { configHooks, settings, init, apply, modelPicker, language } from './settings.mjs';
let right = 'pin',
  nav = false,
  inspector = true;
function tab(kind = right, focus) {
  right = kind;
  inspector = true;
  layout();
  const tabs = [
    ['pin', T('便签', 'Figures')],
    ['note', T('批注', 'Notes')],
    ['chat', T('对话', 'Chat')],
  ];
  $('rightTabs').replaceChildren(
    ...tabs.map(([k, t]) => {
      const b = btn(t, () => tab(k), right === k ? 'active' : '');
      b.setAttribute('aria-label', t);
      b.title = t;
      b.setAttribute('aria-pressed', String(k === right));
      b.replaceChildren(
        icon({ pin: 'pin', note: 'highlighter', chat: 'messages-square' }[k]),
        el('span', { textContent: t })
      );
      if (right === k && k !== 'chat' && S.state)
        b.append(el('small', { textContent: String(S.state.cards.filter((c) => c.kind === k).length) }));
      return b;
    })
  );
  if (!S.doc) return;
  if (right === 'chat') showChat();
  else {
    showCards(right, focus);
    document.querySelector('#canvasArea .composer')?.remove();
    $('ask').hidden = false;
  }
}
function layout() {
  $('navigation').hidden = !nav;
  $('leftDivider').hidden = !nav;
  $('navigation').style.width = Math.min(360, innerWidth * 0.28, S.settings.leftWidth) + 'px';
  $('inspector').hidden = !inspector;
  $('rightDivider').hidden = !inspector;
  $('navToggle').classList.toggle('active', nav);
  $('rightToggle').classList.toggle('active', inspector);
  $('paperTitle').hidden = !nav;
  $('docTitle').hidden = nav;
  const room = Math.max(230, innerWidth - (nav ? $('navigation').offsetWidth + 7 : 0) - 347);
  $('inspector').style.maxWidth = Math.min(innerWidth * 0.5, room) + 'px';
  $('inspector').style.width =
    (S.settings.widths?.[nav ? 'three' : 'two'] || Math.min(50, (336 / innerWidth) * 100)) + '%';
}
function shell() {
  const opened = !!S.doc;
  document.body.classList.toggle('isReading', opened);
  $('appTitle').hidden = opened;
  document.querySelector('[data-library]').hidden = opened;
  $('library').hidden = opened;
  $('desk').hidden = !opened;
  document.querySelectorAll('[data-doc]').forEach((n) => (n.hidden = !opened));
  $('docTitle').textContent = opened ? S.name.replace(/\.pdf$/i, '') : '';
  document.title = opened ? S.name + ' · Folio' : 'Folio';
  $('paperTitle').textContent = $('docTitle').textContent;
  layout();
  if (!opened) {
    const recents = $('recents');
    recents.replaceChildren();
    if (!S.recents.length)
      recents.append(
        el(
          'div',
          { class: 'emptyLibrary' },
          icon('clock'),
          T(
            '将 PDF 拖入窗口，或从本机选择论文。',
            'Drop a PDF here or choose a paper from your computer.'
          )
        )
      );
    for (const r of S.recents) {
      const b = btn('', () => reader.openPaper(() => folio.recent(r.id)), 'recentRow');
      b.append(
        icon('file-text'),
        el(
          'span',
          {},
          el('strong', { textContent: r.name.replace(/\.pdf$/i, '') }),
          el('small', {
            textContent: [r.folder, r.pages ? r.pages + T(' 页', ' pages') : '']
              .filter(Boolean)
              .join(' · '),
          })
        ),
        el('time', {
          textContent: r.date
            ? new Date(r.date).toLocaleDateString(T('zh-CN', 'en-US'), {
                month: 'short',
                day: 'numeric',
              })
            : '',
        }),
        icon('chevron-right')
      );
      b.oncontextmenu = (e) => {
        e.preventDefault();
        popup(
          e.clientX,
          e.clientY,
          btn(T('从最近列表移除', 'Remove from recent papers'), async () => {
            await folio.forgetRecent(r.id);
            S.recents = S.recents.filter((x) => x.id !== r.id);
            shell();
          })
        );
      };
      recents.append(b);
    }
  }
}
function refreshed() {
  apply();
  shell();
  if (S.doc) {
    tab();
    reader.navigation();
    reader.zoomOptions();
    reader.refreshMarks();
  }
}
Object.assign(reader.hooks, {
  openNav: () => {
    nav = true;
    layout();
  },
  opened: () => {
    resetCards();
    setupChat();
    right = 'pin';
    tab(right);
    S.recents = [
      { id: S.id, name: S.name, pages: S.doc.numPages, date: Date.now() },
      ...S.recents.filter((r) => r.id !== S.id),
    ];
  },
  closing: () => {
    resetChat();
    resetCards();
  },
  cards: tab,
  rotated: () => {
    if (right === 'pin') showCards(right);
  },
  changed: () => {
    if (right === 'note') tab(right);
  },
  quote: addReference,
  remove: removeCard,
  shell,
});
Object.assign(cardHooks, { chat: addReference, tab });
Object.assign(chatHooks, {
  tab: () => tab('chat'),
  settings: () => settings('ai'),
  models: modelPicker,
});
Object.assign(configHooks, {
  refresh: refreshed,
  modelsChanged: () => {
    if (right === 'chat' && S.doc) showChat();
  },
});
const open = () => reader.openPaper(() => folio.open(false));
function fileMenu(e) {
  const actions = [
    ['folder-open', T('打开 PDF…', 'Open PDF…'), open],
    ['clock', T('返回最近打开', 'Recently opened'), reader.closePaper],
    ['bookmark-plus', T('添加书签', 'Add bookmark'), reader.bookmark],
    ['notebook-pen', T('导出 Markdown 笔记…', 'Export Markdown notes…'), exportNotes],
    ['file-output', T('提取页面为 PDF…', 'Extract pages to PDF…'), reader.extract],
    ['printer', T('打印…', 'Print…'), () => reader.printPaper(false)],
    ['file-text', T('打印当前页', 'Print current page'), () => reader.printPaper(true)],
    ['scan', T('全屏', 'Fullscreen'), folio.fullscreen],
    ['globe', T('界面语言', 'Language'), language],
    ['settings', T('设置…', 'Settings…'), () => settings()],
  ];
  menu(e.clientX, e.clientY, ...actions.map(([symbol, l, f]) => action(symbol, l, f)));
}
const on = (id, fn) => $(id).addEventListener('click', guard(fn));
on('rightToggle', () => {
  inspector = !inspector;
  layout();
});
on('libraryOpen', open);
on('settings', () => settings());
on('lang', language);
on('more', fileMenu);
on('navToggle', () => {
  nav = !nav;
  layout();
  reader.revealCurrentThumb();
});
on('clip', reader.toggleClip);
on('ask', openComposer);
on('findToggle', () => reader.showFind($('findBar').hidden));
on('closeFind', () => reader.showFind(false));
on('prevMatch', () => reader.search(true, true));
on('nextMatch', () => reader.search(true));
$('query').oninput = () => reader.search();
$('query').onkeydown = (e) => {
  if (e.key === 'Enter') reader.search(true, e.shiftKey);
  if (e.key === 'Escape') reader.showFind(false);
};
on('back', reader.back);
on('previous', () => reader.go(reader.current() - 1));
on('next', () => reader.go(reader.current() + 1));
$('page').onchange = (e) => reader.go(e.target.value);
$('page').onkeydown = (e) => {
  if (e.key === 'Enter') {
    reader.go(e.target.value);
    $('viewerContainer').focus();
  }
};
$('zoom').onchange = guard(async (e) => {
  if (e.target.value !== 'custom') {
    reader.view.currentScaleValue = e.target.value;
    return;
  }
  const raw = await inputDialog(
    T('缩放比例（8–800%）', 'Zoom (8–800%)'),
    String(Math.round(reader.view.currentScale * 100))
  );
  if (raw !== null && Number.isFinite(+raw) && +raw >= 8 && +raw <= 800)
    reader.view.currentScale = +raw / 100;
  reader.zoomOptions();
});
on('zoomIn', () => reader.zoomBy(1.15));
on('zoomOut', () => reader.zoomBy(1 / 1.15));
on('display', (e) => {
  menu(
    e.clientX,
    e.clientY,
    btn(T('连续滚动', 'Continuous scroll'), () => {
      if (!S.state.continuous) reader.mode();
    }),
    btn(T('单页翻阅', 'Single page'), () => {
      if (S.state.continuous) reader.mode();
    }),
    btn(T('旋转', 'Rotate'), reader.rotate)
  );
});
for (const [id, left] of [
  ['leftDivider', true],
  ['rightDivider', false],
]) {
  const div = $(id);
  div.onpointerdown = (e) => {
    div.setPointerCapture(e.pointerId);
    div.onpointermove = (ev) => {
      if (left) S.settings.leftWidth = Math.max(120, Math.min(innerWidth * 0.28, ev.clientX));
      else
        S.settings.widths[nav ? 'three' : 'two'] = Math.max(
          20,
          Math.min(50, ((innerWidth - ev.clientX) / innerWidth) * 100)
        );
      layout();
    };
    div.onpointerup = () => {
      div.onpointermove = null;
      preference({ leftWidth: S.settings.leftWidth, widths: S.settings.widths }).catch(report);
    };
  };
}
function chatDrop(target) {
  target.ondragover = (e) => {
    if (e.dataTransfer.types.includes('application/x-folio-card')) {
      e.preventDefault();
      target.classList.add('active');
    }
  };
  target.ondragleave = () => target.classList.remove('active');
  target.ondrop = guard((e) => {
    e.preventDefault();
    target.classList.remove('active');
    const card = S.state?.cards.find((c) => c.id === e.dataTransfer.getData('application/x-folio-card'));
    if (card) addReference(card);
  });
}
chatDrop($('ask'));
window.addEventListener('dragover', (e) => {
  if (e.dataTransfer.types.includes('Files')) e.preventDefault();
});
window.addEventListener(
  'drop',
  guard(async (e) => {
    e.preventDefault();
    const file = [...e.dataTransfer.files].find((f) => /\.pdf$/i.test(f.name));
    if (file) await reader.openPaper(() => folio.dropPDF(file));
  })
);
$('viewerContainer').addEventListener(
  'wheel',
  (e) => {
    if (e.ctrlKey && S.doc) {
      e.preventDefault();
      reader.zoomBy(e.deltaY < 0 ? 1.08 : 1 / 1.08);
    }
  },
  { passive: false }
);
window.addEventListener(
  'keydown',
  guard((e) => {
    if (document.querySelector('dialog[open]')) return;
    const key = e.key.toLowerCase(),
      mod = e.ctrlKey || e.metaKey;
    if (mod && key === 'o') {
      e.preventDefault();
      return open();
    }
    if (!S.doc) return;
    if (mod && ['f', 'p', 'l', 'd', '[', 'w'].includes(key)) {
      e.preventDefault();
      if (key === 'f') reader.showFind();
      if (key === 'p') return reader.printPaper(false);
      if (key === 'l') {
        $('page').focus();
        $('page').select();
      }
      if (key === 'd') return reader.bookmark();
      if (key === '[') reader.back();
      if (key === 'w') return reader.closePaper();
    }
    if (key === 'f11') {
      e.preventDefault();
      return folio.fullscreen();
    }
    if (e.target.closest('input,textarea,select,[contenteditable=true]')) return;
    if (key === 'escape') {
      hidePopup();
      reader.showFind(false);
      if ($('clip').classList.contains('active')) reader.toggleClip();
    }
    if (
      [
        'home',
        'end',
        'pagedown',
        'pageup',
        'arrowleft',
        'arrowright',
        ' ',
        'arrowdown',
        'arrowup',
      ].includes(key)
    ) {
      const container = $('viewerContainer');
      e.preventDefault();
      if (key === 'home' || key === 'end') reader.go(key === 'home' ? 1 : S.doc.numPages);
      else if (['arrowdown', 'arrowup', ' '].includes(key) && S.state.continuous)
        container.scrollBy({
          top:
            key === ' '
              ? container.clientHeight * (e.shiftKey ? -0.9 : 0.9)
              : key === 'arrowup'
                ? -50
                : 50,
        });
      else
        reader.go(
          reader.current() +
            (['pageup', 'arrowleft', 'arrowup'].includes(key) || (key === ' ' && e.shiftKey) ? -1 : 1)
        );
    }
  })
);
window.addEventListener('resize', layout);
matchMedia('(prefers-color-scheme:dark)').addEventListener('change', apply);
folio.on('open', () => reader.openPaper(() => folio.open(true)).catch(report));
folio.on('closing', async () => {
  try {
    await flush();
    await folio.closed(true);
  } catch (e) {
    report(e);
    await folio.closed(false);
  }
});
window.addEventListener('unhandledrejection', (e) => report(e.reason));
document.body.dataset.host = navigator.userAgent.includes('Windows') ? 'windows' : 'mac';
init(await folio.init());
shell();
await folio.ready();

// The collapsed composer can be moved without opening it, just like its expanded header.
const pill = $('ask');
pill.addEventListener('pointerdown', (event) => {
  if (event.button !== 0) return;
  const bounds = $('canvasArea').getBoundingClientRect(),
    start = pill.getBoundingClientRect();
  const x = event.clientX,
    y = event.clientY;
  let moved = false;
  pill.setPointerCapture(event.pointerId);
  const move = (pointer) => {
    const dx = pointer.clientX - x,
      dy = pointer.clientY - y;
    if (!moved && Math.hypot(dx, dy) < 4) return;
    moved = true;
    const left = Math.max(0, Math.min(bounds.width - start.width, start.left - bounds.left + dx));
    const top = Math.max(0, Math.min(bounds.height - start.height, start.top - bounds.top + dy));
    Object.assign(pill.style, { left: left + 'px', top: top + 'px', right: 'auto', bottom: 'auto' });
  };
  const end = () => {
    pill.removeEventListener('pointermove', move);
    if (moved)
      pill.addEventListener(
        'click',
        (e) => {
          e.preventDefault();
          e.stopImmediatePropagation();
        },
        { once: true, capture: true }
      );
  };
  pill.addEventListener('pointermove', move);
  pill.addEventListener('lostpointercapture', end, { once: true });
});
