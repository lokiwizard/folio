import {
  S,
  T,
  $,
  el,
  btn,
  icon,
  iconButton,
  select,
  row,
  modal,
  inputDialog,
  save,
  preference,
  uid,
  pageLabel,
  toast,
  guard,
  report,
} from './ui.mjs';
import { current, loadTask, renderCrop, requireCopy } from './reader.mjs';
import { rawPin } from './editor.mjs';
import { renderMath } from '../assets/math/render.mjs';
export const chatHooks = { tab: () => {}, settings: () => {}, models: () => {} };
const limits = { file: 64 * 1024 ** 2, message: 12 * 1024 ** 2 };
let draft = '',
  attachments = [],
  includePage = false,
  whole = true,
  token = null,
  loading = false,
  floating = true,
  position = null;
const threads = () => S.state.chats;
const active = () => threads().find((c) => c.id === S.state.chatId);
function newSession() {
  const c = { id: uid(), turns: [], whole: true };
  threads().unshift(c);
  S.state.chatId = c.id;
  clearDraft();
  save();
  return c;
}
function clearDraft() {
  attachments = [];
  draft = '';
  includePage = false;
  whole = active()?.whole ?? true;
}
export function resetChat() {
  document.querySelector('#canvasArea .composer')?.remove();
  $('ask').hidden = false;
  if (token) folio.stop(token);
  token = null;
  loading = false;
  attachments = [];
  draft = '';
  whole = true;
  includePage = false;
  floating = true;
  position = null;
}
export function setupChat() {
  clearDraft();
}
function title(c) {
  return c.turns[0]?.question?.slice(0, 42) || T('新对话', 'New chat');
}
function label(c) {
  return c.title || c.name || [...new Set((c.anchors || []).map((a) => pageLabel(a.page)))].join(', ');
}
export function addReference(card) {
  requireCopy();
  if (!active()) newSession();
  if (!attachments.some((c) => c === card || (c.id && c.id === card.id))) attachments.push(card);
  whole = false;
  chatHooks.tab();
  $('question')?.focus();
}
export function openComposer() {
  chatHooks.tab();
  $('question')?.focus();
}
async function pageContents(doc, pg) {
  const p = await doc.getPage(pg);
  const text = (await p.getTextContent()).items
    .map((i) => (i.str || '') + (i.hasEOL ? '\n' : ' '))
    .join('')
    .trim();
  if (text) return { text: pageLabel(pg) + '\n' + text, images: [] };
  return {
    text: pageLabel(pg),
    images: [(await renderCrop(doc, pg, null, 1600)).toDataURL('image/jpeg', 0.82)],
  };
}
function checkSize(text, images) {
  const size =
    new TextEncoder().encode(text).length + images.reduce((n, img) => n + img.length * 0.75, 0);
  if (size > limits.message)
    throw Error(T('附件内容过大，请拆分文件。', 'Attachments are too large. Split the document.'));
}
async function readFile(file) {
  if (file.size > limits.file) throw Error(T('单个文件超过 64 MiB', 'File exceeds 64 MiB'));
  let text = '',
    images = [];
  if (file.type === 'application/pdf' || /\.pdf$/i.test(file.name)) {
    const job = loadTask(new Uint8Array(await file.arrayBuffer()));
    try {
      const doc = await job.promise;
      const rights = await doc.getPermissions();
      if (rights && !rights.has(16)) throw Error(T('PDF 限制复制', 'Copying is restricted'));
      for (let n = 1; n <= doc.numPages; n++) {
        const p = await pageContents(doc, n);
        text += p.text + '\n';
        images.push(...p.images);
        checkSize(text, images);
      }
    } finally {
      await job.destroy();
    }
  } else if (file.type.startsWith('image/')) {
    const image = await createImageBitmap(file);
    try {
      const f = Math.min(1, 2048 / Math.max(image.width, image.height)),
        c = el('canvas', {
          width: Math.max(1, Math.round(image.width * f)),
          height: Math.max(1, Math.round(image.height * f)),
        });
      const ctx = c.getContext('2d');
      ctx.fillStyle = 'white';
      ctx.fillRect(0, 0, c.width, c.height);
      ctx.drawImage(image, 0, 0, c.width, c.height);
      images.push(c.toDataURL('image/jpeg', 0.82));
    } finally {
      image.close();
    }
  } else if (/\.(txt|md|markdown|csv|json)$/i.test(file.name) || file.type.startsWith('text/')) {
    const data = new Uint8Array(await file.arrayBuffer());
    let encoding = 'utf-8';
    if (data[0] === 255 && data[1] === 254) encoding = 'utf-16le';
    else if (data[0] === 254 && data[1] === 255) encoding = 'utf-16be';
    text = new TextDecoder(encoding, { fatal: true }).decode(data);
  } else throw Error(T('请选择图片、PDF 或文本文件。', 'Choose an image, PDF or text file.'));
  checkSize(text, images);
  return { id: uid(), kind: 'file', name: file.name, text, images };
}
async function addFiles(files) {
  const id = S.id,
    chatId = S.state.chatId;
  const results = [];
  for (const f of files) results.push(await readFile(f));
  if (id !== S.id || chatId !== S.state.chatId) return;
  attachments.push(...results);
  whole = false;
  chatHooks.tab();
}
async function message(c) {
  const question = draft.trim();
  if (!question) throw Error(T('请输入问题', 'Enter a question'));
  const parts = [],
    images = [];
  const append = (p) => {
    parts.push(p.text);
    images.push(...p.images);
    checkSize(parts.join('\n'), images);
  };
  const doc = S.doc,
    refs = [...attachments];
  if (whole && !c.turns.some((t) => t.full)) {
    requireCopy();
    for (let n = 1; n <= doc.numPages; n++) append(await pageContents(doc, n));
  } else if (includePage) {
    requireCopy();
    append(await pageContents(doc, current()));
  }
  for (const item of refs) {
    if (item.kind === 'file') append({ text: label(item) + '\n' + item.text, images: item.images });
    else if (item.kind === 'pin') {
      requireCopy();
      append({
        text: label(item) + ' · ' + pageLabel(item.anchors[0].page),
        images: [(await rawPin(item, 1800)).toDataURL('image/jpeg', 0.85)],
      });
    } else {
      requireCopy();
      append({ text: label(item) + '\n' + item.text, images: [] });
    }
  }
  parts.push(question);
  checkSize(parts.join('\n'), images);
  return { role: 'user', text: parts.join('\n\n'), images };
}
function history(c) {
  return c.turns.flatMap((t) => [
    { role: 'user', text: t.payload.text, images: t.payload.images },
    { role: 'assistant', text: t.answer },
  ]);
}
async function run(preview = false) {
  if (loading || token) return;
  const profile = S.profiles.find((p) => p.id === S.settings.active);
  if (!profile) {
    chatHooks.settings();
    return;
  }
  const c = active() || newSession(),
    id = S.id;
  // Keep the draft intact if this is the first turn.
  loading = true;
  let request;
  try {
    const msg = await message(c);
    if (S.id !== id || S.state.chatId !== c.id) return;
    const messages = [...history(c), msg];
    if (preview) {
      const content = el(
        'div',
        {},
        el('p', { textContent: profile.provider + ' · ' + profile.model + ' · ' + profile.base })
      );
      for (const m of messages) {
        content.append(el('strong', { textContent: m.role }), el('pre', { textContent: m.text }));
        for (const src of m.images || []) {
          const image = el('img', { src });
          image.style.maxWidth = '280px';
          content.append(image);
        }
      }
      modal(T('发送内容预览', 'Request preview'), content);
      return;
    }
    request = uid();
    token = request;
    const turn = {
      id: uid(),
      question: draft.trim(),
      names: attachments.map(label),
      full: whole && !c.turns.some((t) => t.full),
      payload: msg,
      answer: '',
    };
    c.whole = whole;
    c.turns.push(turn);
    attachments = [];
    includePage = false;
    draft = '';
    save();
    showChat();
    try {
      const answer = await folio.chat(profile.id, request, messages);
      turn.answer = answer;
    } catch (e) {
      if (!turn.answer) c.turns = c.turns.filter((t) => t !== turn);
      if (!turn.answer && S.id === id) draft = turn.question;
      if (!/abort/i.test(e.message)) throw e;
    } finally {
      if (S.id === id) {
        save();
        if (token === request) token = null;
        if ($('thread')) showChat();
      }
    }
  } finally {
    loading = false;
    if (token === request) token = null;
  }
}
folio.on('delta', ({ token: t, text }) => {
  if (t !== token || !S.state) return;
  const turn = active()?.turns.at(-1);
  if (!turn) return;
  turn.answer += text;
  const target = document.getElementById('answer-' + turn.id);
  if (target) {
    const thread = $('thread'),
      bottom = thread.scrollHeight - thread.scrollTop - thread.clientHeight < 60;
    renderMath(turn.answer, target);
    if (bottom) thread.scrollTop = thread.scrollHeight;
  }
});
export function showChat() {
  document.querySelector('#canvasArea .composer')?.remove();
  $('ask').hidden = floating;
  const host = $('rightContent');
  host.ondragover = null;
  host.replaceChildren();
  let c = active();
  if (!c) c = newSession();
  const thread = el('div', { class: 'thread', id: 'thread' }),
    timeline = el('div', { class: 'timeline' }),
    root = el('div', { class: 'chatbox' });
  host.append(root);
  const switcher = select(
    threads().map((s) => [s.id, title(s)]),
    c.id,
    (id) => {
      if (token) return;
      S.state.chatId = id;
      clearDraft();
      save();
      showChat();
    }
  );
  switcher.disabled = !!token;
  const add = iconButton('plus', T('新对话', 'New chat'), () => {
      if (!token) {
        newSession();
        showChat();
      }
    }),
    del = iconButton('trash-2', T('删除对话', 'Delete chat'), () => {
      if (token) return;
      S.state.chats = threads().filter((t) => t.id !== c.id);
      S.state.chatId = threads()[0]?.id;
      clearDraft();
      save();
      showChat();
    });
  root.append(row(switcher, add, del), thread, timeline);
  for (const t of c.turns) {
    const q = el('div', { class: 'message user', textContent: [...t.names, t.question].join('\n') });
    q.oncontextmenu = (e) => {
      e.preventDefault();
      if (token) return;
      const d = modal(
        T('删除这轮问答？', 'Delete this turn?'),
        btn(T('删除', 'Delete'), () => {
          c.turns = c.turns.filter((x) => x !== t);
          save();
          d.close();
          showChat();
        })
      );
    };
    const a = el('div', { class: 'message', id: 'answer-' + t.id });
    renderMath(t.answer, a);
    thread.append(q, a);
    timeline.append(btn('●', () => q.scrollIntoView({ block: 'start' })));
  }
  if (!c.turns.length) {
    for (const p of S.settings.prompts) {
      const b = btn(typeof p === 'string' ? p : T(p.zh, p.en), () => {
        draft = b.textContent;
        $('question').value = draft;
        $('question').focus();
      });
      thread.append(b);
    }
  }
  const composer = el('section', { class: 'composer' + (floating ? ' floating' : '') });
  (floating ? $('canvasArea') : root).append(composer);
  const grip = el('strong', { textContent: T('问 AI', 'Ask AI') });
  grip.style.cursor = 'move';
  grip.prepend(icon('message-square'));
  const promptEdit = btn(T('提示词', 'Prompts'), async () => {
    const initial = S.settings.prompts
      .map((p) => (typeof p === 'string' ? p : T(p.zh, p.en)))
      .join('\n');
    const s = await inputDialog(T('初始问题，每行一条', 'Starter questions, one per line'), initial, {
      multi: true,
    });
    if (s !== null) {
      await preference({
        prompts: s
          .split('\n')
          .map((x) => x.trim())
          .filter(Boolean),
      });
      showChat();
    }
  });
  root.firstElementChild.append(el('span', { class: 'space' }), promptEdit);
  const heading = row(grip, el('span', { class: 'space' }));
  heading.classList.add('composerHead');
  composer.append(heading);
  const collapse = iconButton('chevron-down', T('收起', 'Collapse'), () => {
    composer.hidden = true;
    $('ask').hidden = false;
  });
  if (floating && position)
    Object.assign(composer.style, {
      left: position.x + 'px',
      top: position.y + 'px',
      bottom: 'auto',
      right: 'auto',
    });
  grip.onpointerdown = (e) => {
    if (!floating) return;
    grip.setPointerCapture(e.pointerId);
    const bounds = $('canvasArea').getBoundingClientRect(),
      r = composer.getBoundingClientRect(),
      dx = e.clientX - r.x,
      dy = e.clientY - r.y;
    grip.onpointermove = (ev) => {
      position = {
        x: Math.max(0, Math.min(bounds.width - composer.offsetWidth, ev.clientX - bounds.left - dx)),
        y: Math.max(0, Math.min(bounds.height - composer.offsetHeight, ev.clientY - bounds.top - dy)),
      };
      Object.assign(composer.style, {
        left: position.x + 'px',
        top: position.y + 'px',
        bottom: 'auto',
        right: 'auto',
      });
    };
    grip.onpointerup = () => (grip.onpointermove = null);
  };
  const chips = el('div', { class: 'tools' });
  attachments.forEach((r, i) =>
    chips.append(
      btn(
        label(r) + ' ×',
        () => {
          attachments.splice(i, 1);
          showChat();
        },
        'chip'
      )
    )
  );
  composer.append(chips);
  if (attachments.some((a) => a.kind === 'note' && !a.id)) {
    for (const a of attachments.filter((a) => a.kind === 'note' && !a.id)) {
      const source = el('blockquote', { class: 'citedPassage', textContent: a.text });
      chips.prepend(source);
    }
  }
  if (attachments.some((a) => a.kind === 'note')) {
    for (const t of [T('解释', 'Explain'), T('翻译', 'Translate'), T('总结', 'Summarize')])
      chips.append(
        btn(t, () => {
          draft = t;
          $('question').value = t;
        })
      );
  }
  const q = el('textarea', {
    id: 'question',
    rows: 3,
    value: draft,
    placeholder: T('输入问题…', 'Ask a question…'),
  });
  q.oninput = () => (draft = q.value);
  q.onkeydown = guard(async (e) => {
    if (e.key === 'Enter' && e.ctrlKey) {
      e.preventDefault();
      await run();
    }
  });
  q.onpaste = guard(async (e) => {
    const files = [...e.clipboardData.files];
    if (files.length) {
      e.preventDefault();
      await addFiles(files);
      return;
    }
    if (navigator.userAgent.includes('Windows') && !e.clipboardData.getData('text/plain')) {
      e.preventDefault();
      const copied = await folio.copiedFiles();
      if (copied.length)
        await addFiles(copied.map((f) => new File([f.bytes], f.name, { type: f.type })));
    }
  });
  const picker = el('input', {
    type: 'file',
    multiple: true,
    accept: 'image/*,.pdf,.txt,.md,.markdown,.csv,.json',
    hidden: true,
    onchange: (e) => addFiles([...e.target.files]),
  });
  const scope = select(
    [
      ['whole', T('全文', 'Whole paper')],
      ['page', T('当前页', 'Current page')],
      ['refs', T('仅引用', 'References')],
    ],
    whole ? 'whole' : includePage ? 'page' : 'refs',
    (v) => {
      whole = v === 'whole';
      includePage = v === 'page';
      c.whole = whole;
      save();
    }
  );
  heading.append(scope, collapse);
  const service = btn(
    S.profiles.find((p) => p.id === S.settings.active)?.model ||
      T('配置 AI 服务', 'Configure AI service'),
    chatHooks.models,
    'modelButton'
  );
  service.prepend(icon('cpu'));
  const send = token
    ? iconButton('square', T('停止', 'Stop'), () => folio.stop(token))
    : iconButton('arrow-up', T('发送', 'Send'), () => run());
  send.classList.add('sendButton');
  composer.append(
    q,
    el(
      'div',
      { class: 'composerFoot' },
      service,
      el('span', { class: 'space' }),
      iconButton('paperclip', T('添加文件', 'Attach files'), () => picker.click()),
      picker,
      iconButton('eye', T('预览', 'Preview'), () => run(true)),
      send
    )
  );
  composer.ondragover = (e) => e.preventDefault();
  composer.ondrop = guard(async (e) => {
    e.preventDefault();
    e.stopPropagation();
    const id = e.dataTransfer.getData('application/x-folio-card');
    if (id) {
      const card = S.state.cards.find((c) => c.id === id);
      if (card) addReference(card);
    } else await addFiles([...e.dataTransfer.files]);
  });
  thread.scrollTop = thread.scrollHeight;
}
