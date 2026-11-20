import {
  S,
  T,
  el,
  btn,
  icon,
  select,
  row,
  modal,
  inputDialog,
  preference,
  uid,
  toast,
  save,
  localize,
} from './ui.mjs';
export const configHooks = { refresh: () => {}, modelsChanged: () => {} };
const palette = ['#e87b72', '#68a9d6', '#71b893', '#a686c8', '#e6c452'];
const tagNames = [
  ['局限', 'Limitations'],
  ['疑问', 'Questions'],
  ['核心创新', 'Key ideas'],
  ['写作参考', 'Writing reference'],
  ['默认', 'Default'],
];
const prompts = [
  ['这篇论文解决了什么问题？', 'What problem does this paper address?'],
  ['主要结论有哪些实验证据？', 'What evidence supports the main findings?'],
  ['从输入到输出，这个方法分哪几步？', 'How does the method go from input to output?'],
  ['和已有方法相比，关键改进在哪里？', 'How does this method improve on prior work?'],
  ['作者提到了哪些局限或失败案例？', 'What limitations or failure cases do the authors report?'],
];
let endpoints = {};
export function init(config) {
  endpoints = config.endpoints;
  S.profiles = config.profiles;
  S.recents = config.recents;
  S.settings = {
    lang: 'zh',
    theme: 'system',
    glass: 65,
    font: 14,
    defaultTag: 'preset-4',
    tags: tagNames.map(([name, en], i) => ({
      id: 'preset-' + i,
      name,
      en,
      preset: name,
      color: palette[i],
    })),
    prompts: prompts.map(([zh, en]) => ({ zh, en })),
    widths: { three: 0, two: 0 },
    leftWidth: 244,
    ...config.settings,
  };
  apply();
}
export function apply() {
  const s = S.settings;
  document.documentElement.dataset.dark = String(
    s.theme === 'dark' || (s.theme === 'system' && matchMedia('(prefers-color-scheme:dark)').matches)
  );
  document.documentElement.style.setProperty('--glass', s.glass + '%');
  document.documentElement.style.setProperty('--memo', s.font + 'px');
  localize();
}
export const tagTitle = (t) => (t.preset === t.name && t.en ? T(t.name, t.en) : t.name);
export async function language() {
  await preference({ lang: S.settings.lang === 'en' ? 'zh' : 'en' });
  apply();
  configHooks.refresh();
}
const field = (label, input) => el('label', { class: 'field' }, label, input);
export function settings(tab = 'appearance') {
  const body = el('div'),
    sidebar = el('aside'),
    content = el('main'),
    grid = el('div', { class: 'settingsGrid' }, sidebar, content),
    d = modal(T('设置', 'Settings'));
  d.className = 'settingsSheet';
  d.replaceChildren(grid);
  const options = [
    ['appearance', T('外观', 'Appearance'), 'contrast'],
    ['tags', T('语义高亮', 'Highlights'), 'highlighter'],
    ['ai', T('AI 服务', 'AI services'), 'globe'],
  ];
  function show(t) {
    body.replaceChildren();
    sidebar.replaceChildren(el('h2', { textContent: T('设置', 'Settings') }));
    for (const [key, name, symbol] of options) {
      const b = btn(name, () => show(key), key === t ? 'active' : '');
      b.prepend(icon(symbol));
      sidebar.append(b);
    }
    sidebar.append(
      el('div', { class: 'space' }),
      btn(T('简体中文 ⌄', 'English ⌄'), async () => {
        await language();
        d.close();
        settings(t);
      })
    );
    content.replaceChildren(
      el(
        'div',
        { class: 'dialogHead' },
        el('h2', { textContent: options.find((x) => x[0] === t)[1] }),
        btn(T('完成', 'Done'), () => d.close())
      ),
      body
    );
    if (t === 'appearance') {
      const change = async (values) => {
        await preference(values);
        apply();
        configHooks.refresh();
      };
      const swatches = el('div', { class: 'swatches' });
      for (const [v, title] of [
        ['system', T('跟随系统', 'System')],
        ['light', T('浅色', 'Light')],
        ['dark', T('深色', 'Dark')],
      ]) {
        const b = btn(
          '',
          async () => {
            await change({ theme: v });
            show(t);
          },
          S.settings.theme === v ? 'active' : ''
        );
        b.append(el('i', { class: v }), title);
        swatches.append(b);
      }
      const group = (title, ...nodes) =>
        el('section', { class: 'group' }, el('h3', { textContent: title }), ...nodes);
      const strength = el('input', { type: 'range', min: 0, max: 100, value: S.settings.glass });
      const number = el('span', { textContent: S.settings.glass + '%' });
      strength.oninput = () => {
        number.textContent = strength.value + '%';
        change({ glass: +strength.value });
      };
      const glass = el(
        'div',
        { class: 'glassPreview' },
        el('div', { class: 'askPill' }, el('i', { class: 'askSymbol' }), T('问 AI', 'Ask AI'))
      );
      body.append(
        group(T('窗口外观', 'Window appearance'), swatches),
        group(
          T('备注字号', 'Note font size'),
          select(
            Array.from({ length: 23 }, (_, i) => [String(i + 10), i + 10 + ' pt']),
            String(S.settings.font),
            (v) => change({ font: +v })
          )
        ),
        group(T('毛玻璃强度', 'Glass intensity'), row(strength, number), glass)
      );
    } else if (t === 'tags') {
      const update = async () => {
        await preference({ tags: S.settings.tags, defaultTag: S.settings.defaultTag });
        configHooks.refresh();
        show(t);
      };
      for (const tag of S.settings.tags) {
        const name = el('input', {
          value: tagTitle(tag),
          onchange: async (e) => {
            if (e.target.value.trim()) {
              tag.name = e.target.value.trim();
              tag.preset = null;
              await update();
            }
          },
        });
        const color = el('input', {
          type: 'color',
          value: tag.color,
          onchange: async (e) => {
            tag.color = e.target.value;
            tag.override = true;
            await update();
          },
        });
        body.append(
          row(
            color,
            name,
            btn(tag.id === S.settings.defaultTag ? '●' : '○', async () => {
              S.settings.defaultTag = tag.id;
              await update();
            }),
            btn(T('删除', 'Delete'), async () => {
              if (S.settings.tags.length <= 1) return;
              S.settings.tags = S.settings.tags.filter((t) => t !== tag);
              if (tag.id === S.settings.defaultTag) S.settings.defaultTag = S.settings.tags[0].id;
              for (const c of S.state?.cards || []) if (c.tag === tag.id) c.tag = S.settings.defaultTag;
              if (S.state) save();
              await update();
            })
          )
        );
      }
      body.append(
        btn(T('添加标签', 'Add tag'), async () => {
          const name = await inputDialog(T('标签名称', 'Tag name'));
          if (name?.trim()) {
            S.settings.tags.push({ id: uid(), name: name.trim(), color: '#73b588' });
            await update();
          }
        })
      );
    } else serviceForm(body, () => show(t));
  }
  show(tab);
}
function absorb(result) {
  S.profiles = result.profiles;
  S.settings.active = result.settings.active;
  configHooks.modelsChanged();
}
function serviceForm(body, refresh) {
  let selected = S.profiles.find((p) => p.id === S.settings.active) || S.profiles[0];
  const chooser = select(
    [['', T('添加服务', 'Add service')], ...S.profiles.map((p) => [p.id, p.provider + ' · ' + p.model])],
    selected?.id || '',
    (id) => {
      selected = S.profiles.find((p) => p.id === id);
      fill();
    }
  );
  const provider = select(
    Object.keys(endpoints).map((p) => [p, p]),
    selected?.provider || 'OpenAI',
    (v) => {
      base.value = endpoints[v];
      key.value = '';
      model.value = '';
    }
  );
  const base = el('input', { type: 'url' }),
    model = el('input'),
    key = el('input', { type: 'password', autocomplete: 'off' }),
    status = el('output');
  function fill() {
    provider.value = selected?.provider || 'OpenAI';
    base.value = selected?.base || endpoints[provider.value];
    model.value = selected?.model || '';
    key.value = '';
    key.placeholder = selected ? T('留空保留已有密钥', 'Leave blank to keep saved key') : 'API Key';
  }
  fill();
  async function store() {
    const config = await folio.profile({
      provider: provider.value,
      base: base.value.trim(),
      model: model.value.trim(),
      key: key.value.trim(),
    });
    key.value = '';
    absorb(config);
    selected = S.profiles.find((p) => p.id === S.settings.active);
    return selected;
  }
  body.append(
    field(T('账户', 'Account'), chooser),
    field(T('厂商', 'Provider'), provider),
    field(T('HTTPS 服务地址', 'HTTPS service address'), base),
    field('Model ID', model),
    field('API Key', key),
    row(
      btn(
        T('保存并使用', 'Save and use'),
        async () => {
          await store();
          refresh();
          toast(T('已保存', 'Saved'));
        },
        'primary'
      ),
      btn(T('测试连接', 'Test connection'), async () => {
        const p = await store();
        status.textContent = await folio.test(p.id);
      }),
      btn(T('删除服务', 'Remove service'), async () => {
        if (selected) {
          absorb(await folio.removeProfile(selected.id));
          refresh();
        }
      })
    ),
    status
  );
}
export function modelPicker() {
  if (!S.profiles.length) {
    settings('ai');
    return;
  }
  let profile = S.profiles.find((p) => p.id === S.settings.active) || S.profiles[0];
  const search = el('input', {
      type: 'search',
      placeholder: T('搜索或输入模型 ID', 'Search or enter model ID'),
    }),
    list = el('div'),
    body = el('div');
  const d = modal(T('切换模型', 'Choose model'), body);
  const applyModel = async (model) => {
    if (!model.trim()) return;
    absorb(await folio.profile({ ...profile, model: model.trim(), key: '' }));
    d.close();
  };
  function draw() {
    list.replaceChildren(
      ...[...new Set([profile.model, ...profile.models])]
        .filter((m) => m.toLowerCase().includes(search.value.toLowerCase()))
        .map((m) => btn(m, () => applyModel(m)))
    );
  }
  const chooser = select(
    S.profiles.map((p) => [p.id, p.provider + ' · ' + p.base]),
    profile.id,
    (id) => {
      profile = S.profiles.find((p) => p.id === id);
      draw();
    }
  );
  body.append(
    chooser,
    field(T('模型', 'Model'), search),
    row(
      btn(T('刷新目录', 'Refresh catalog'), async () => {
        profile.models = await folio.models(profile.id);
        draw();
      }),
      btn(T('使用输入的 ID', 'Use entered ID'), () => applyModel(search.value)),
      btn(T('配置服务', 'Configure'), () => {
        d.close();
        settings('ai');
      })
    ),
    list
  );
  search.oninput = draw;
  draw();
}
