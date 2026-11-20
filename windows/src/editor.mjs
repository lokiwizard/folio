import {
  Canvas,
  StaticCanvas,
  Rect,
  Ellipse,
  Polyline,
  Textbox,
  PencilBrush,
  Point,
  controlsUtils,
  FabricObject,
  classRegistry,
} from '../assets/fabric.mjs';
import { S, T, el, btn, select, row, modal, inputDialog, save, guard } from './ui.mjs';
import { renderCrop } from './reader.mjs';
FabricObject.customProperties = ['label', 'labelSize', 'arrow', 'folioLine'];
function shapeLabel(ctx, o) {
  if (!o.label) return;
  ctx.save();
  ctx.fillStyle = o.stroke || '#161616';
  ctx.font = (o.labelSize || 24) + 'px sans-serif';
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  const lines = o.label.split('\n');
  lines.forEach((s, i) =>
    ctx.fillText(s, 0, (i - (lines.length - 1) / 2) * (o.labelSize || 24), Math.max(1, o.width - 8))
  );
  ctx.restore();
}
class LabelRect extends Rect {
  static type = 'FolioRect';
  _render(ctx) {
    super._render(ctx);
    shapeLabel(ctx, this);
  }
}
class LabelEllipse extends Ellipse {
  static type = 'FolioEllipse';
  _render(ctx) {
    super._render(ctx);
    shapeLabel(ctx, this);
  }
}
class ArrowLine extends Polyline {
  static type = 'FolioLine';
  _render(ctx) {
    super._render(ctx);
    if (!this.arrow) return;
    const [start, end] = this.points,
      angle = Math.atan2(end.y - start.y, end.x - start.x),
      size = Math.max(10, this.strokeWidth * 4);
    ctx.save();
    ctx.translate(end.x - this.pathOffset.x, end.y - this.pathOffset.y);
    ctx.rotate(angle);
    ctx.fillStyle = this.stroke;
    ctx.beginPath();
    ctx.moveTo(0, 0);
    ctx.lineTo(-size, -size * 0.42);
    ctx.lineTo(-size, size * 0.42);
    ctx.closePath();
    ctx.fill();
    ctx.restore();
  }
}
for (const cls of [LabelRect, LabelEllipse, ArrowLine]) classRegistry.setClass(cls);
const dimensions = (base) => ({ width: base.width, height: base.height });
export async function rawPin(card, max = 1800, rotation = S.state.rotations[card.anchors[0].page] || 0) {
  const a = card.anchors[0];
  return renderCrop(S.doc, a.page, a.rect, max, rotation);
}
async function composite(base, canvas, drawing) {
  const scene = new StaticCanvas(null, { ...dimensions(base), enableRetinaScaling: false });
  try {
    await scene.loadFromJSON(drawing);
    scene.renderAll();
    canvas.getContext('2d').drawImage(scene.lowerCanvasEl, 0, 0, canvas.width, canvas.height);
    return canvas;
  } finally {
    await scene.dispose();
  }
}
export async function artwork(card, max = 1800) {
  if (!card.drawing) return rawPin(card, max);
  const orientation = card.rotation || 0,
    angle = ((S.state.rotations[card.anchors[0].page] || 0) - orientation + 360) % 360;
  const base = await rawPin(card, max, orientation);
  await composite(card.drawingSize || base, base, card.drawing);
  if (!angle) return base;
  const out = el('canvas', {
    width: angle % 180 ? base.height : base.width,
    height: angle % 180 ? base.width : base.height,
  });
  const ctx = out.getContext('2d');
  ctx.translate(out.width / 2, out.height / 2);
  ctx.rotate((angle * Math.PI) / 180);
  ctx.drawImage(base, -base.width / 2, -base.height / 2);
  return out;
}
export async function editor(card, refresh) {
  const base = await rawPin(card, 1800, card.rotation || 0),
    size = card.drawingSize || dimensions(base);
  const tools = el('div', { class: 'tools' }),
    props = el('div', { class: 'tools' }),
    stage = el('div', { class: 'editorStage' }),
    surface = el('canvas');
  stage.append(surface);
  const d = modal(card.title || T('编辑图表便签', 'Edit figure'), tools, props, stage);
  const scene = new Canvas(surface, {
    ...size,
    enableRetinaScaling: false,
    preserveObjectStacking: true,
    selection: true,
  });
  scene.wrapperEl.style.backgroundImage = 'url(' + base.toDataURL() + ')';
  scene.wrapperEl.style.backgroundSize = '100% 100%';
  let tool = 'select',
    draft,
    start,
    history = [],
    future = [],
    restoring = false,
    scale = 1,
    activeColor = '#d14135',
    width = 4,
    dash = false,
    font = 26;
  const buttons = new Map(),
    undo = btn(T('撤销', 'Undo'), () => restore(history, future)),
    redo = btn(T('重做', 'Redo'), () => restore(future, history));
  function data() {
    return scene.toJSON();
  }
  function record() {
    if (restoring || draft) return;
    const json = data();
    if (JSON.stringify(json) === JSON.stringify(card.drawing)) return;
    history.push(card.drawing || { objects: [] });
    if (history.length > 80) history.shift();
    future = [];
    card.drawing = json;
    card.drawingSize = size;
    save();
  }
  async function restore(from, to) {
    if (!from.length || restoring) return;
    restoring = true;
    try {
      to.push(data());
      card.drawing = from.pop();
      await scene.loadFromJSON(card.drawing);
      setupObjects();
      scene.requestRenderAll();
      save();
    } finally {
      restoring = false;
    }
  }
  function setupObjects() {
    for (const o of scene.getObjects())
      if (o instanceof ArrowLine) o.controls = controlsUtils.createPolyControls(o);
  }
  if (card.drawing) {
    await scene.loadFromJSON(card.drawing);
    setupObjects();
  }
  function zoom(value) {
    scale = Math.min(4, Math.max(0.1, value));
    scene.wrapperEl.style.zoom = String(scale);
  }
  function fit() {
    zoom(Math.min((innerWidth * 0.8) / size.width, (innerHeight * 0.6) / size.height, 1));
  }
  function setTool(v) {
    tool = v;
    scene.isDrawingMode = v === 'pen';
    scene.selection = v === 'select';
    scene.skipTargetFind = v !== 'select';
    scene.defaultCursor = v === 'select' ? 'default' : 'crosshair';
    for (const [key, b] of buttons) b.classList.toggle('active', key === v);
    if (scene.isDrawingMode) {
      const brush = new PencilBrush(scene);
      brush.color = activeColor;
      brush.width = width;
      brush.strokeDashArray = dash ? [width * 3, width * 2] : null;
      scene.freeDrawingBrush = brush;
    }
  }
  const names = [
    ['select', T('选择', 'Select')],
    ['pen', T('画笔', 'Pen')],
    ['line', T('直线', 'Line')],
    ['arrow', T('箭头', 'Arrow')],
    ['rect', T('矩形', 'Rectangle')],
    ['ellipse', T('椭圆', 'Ellipse')],
    ['text', T('文本框', 'Text')],
  ];
  for (const [key, name] of names) {
    const b = btn(name, () => setTool(key));
    buttons.set(key, b);
    tools.append(b);
  }
  function styleSelected() {
    const o = scene.getActiveObject();
    if (o) {
      if (o instanceof Textbox) o.set({ fill: activeColor, fontSize: font });
      else
        o.set({
          stroke: activeColor,
          strokeWidth: width,
          strokeDashArray: dash ? [width * 3, width * 2] : null,
          labelSize: font,
        });
      o.set('dirty', true);
      scene.requestRenderAll();
      record();
    }
    if (tool === 'pen') setTool(tool);
  }
  const color = el('input', {
    type: 'color',
    value: activeColor,
    oninput: (e) => {
      activeColor = e.target.value;
      styleSelected();
    },
  });
  props.append(
    color,
    T('线宽', 'Width'),
    el('input', {
      type: 'number',
      min: 1,
      max: 32,
      value: width,
      onchange: (e) => {
        width = Math.max(1, Math.min(32, +e.target.value));
        styleSelected();
      },
    }),
    select(
      [
        ['solid', T('实线', 'Solid')],
        ['dash', T('虚线', 'Dashed')],
      ],
      'solid',
      (v) => {
        dash = v === 'dash';
        styleSelected();
      }
    ),
    T('字号', 'Font'),
    el('input', {
      type: 'number',
      min: 8,
      max: 160,
      value: font,
      onchange: (e) => {
        font = Math.max(8, Math.min(160, +e.target.value));
        styleSelected();
      },
    })
  );
  const remove = () => {
    const o = scene.getActiveObject();
    if (o && !o.isEditing) {
      scene.remove(...scene.getActiveObjects());
      scene.discardActiveObject();
      scene.requestRenderAll();
      record();
    }
  };
  tools.append(
    undo,
    redo,
    btn(T('删除', 'Delete'), remove),
    btn('−', () => zoom(scale / 1.25)),
    btn('+', () => zoom(scale * 1.25)),
    btn(T('全图', 'Fit'), fit),
    btn(T('复制图片', 'Copy image'), async () => folio.copyImage((await artwork(card)).toDataURL()))
  );
  function shape(p) {
    const dx = p.x - start.x,
      dy = p.y - start.y,
      w = Math.max(2, Math.abs(dx)),
      h = Math.max(2, Math.abs(dy));
    const style = {
      left: Math.min(start.x, p.x),
      top: Math.min(start.y, p.y),
      originX: 'left',
      originY: 'top',
      fill: 'transparent',
      stroke: activeColor,
      strokeWidth: width,
      strokeDashArray: dash ? [width * 3, width * 2] : null,
      strokeUniform: true,
    };
    if (tool === 'rect') return new LabelRect({ ...style, width: w, height: h });
    if (tool === 'ellipse') return new LabelEllipse({ ...style, rx: w / 2, ry: h / 2 });
    if (tool === 'text')
      return new Textbox('', {
        ...style,
        fill: activeColor,
        stroke: null,
        width: Math.max(50, w),
        fontSize: font,
        editable: true,
      });
    const pts = [new Point(start.x, start.y), new Point(p.x, p.y)];
    return new ArrowLine(pts, {
      fill: null,
      stroke: activeColor,
      strokeWidth: width,
      strokeDashArray: style.strokeDashArray,
      arrow: tool === 'arrow',
    });
  }
  scene.on('mouse:down', ({ scenePoint }) => {
    if (['select', 'pen'].includes(tool)) return;
    start = scenePoint;
    draft = shape(start);
    scene.add(draft);
  });
  scene.on('mouse:move', ({ scenePoint }) => {
    if (!draft) return;
    scene.remove(draft);
    draft = shape(scenePoint);
    scene.add(draft);
    scene.requestRenderAll();
  });
  scene.on('mouse:up', () => {
    if (!draft) return;
    const o = draft;
    draft = null;
    setupObjects();
    setTool('select');
    scene.setActiveObject(o);
    if (o instanceof Textbox) o.enterEditing();
    scene.requestRenderAll();
    record();
  });
  scene.on('path:created', ({ path }) => {
    setTool('select');
    scene.setActiveObject(path);
    record();
  });
  scene.on('object:modified', record);
  scene.on('text:editing:exited', record);
  async function editLabel(o, initial) {
    if (!(o instanceof LabelRect || o instanceof LabelEllipse)) return;
    const text = await inputDialog(T('形状文字', 'Shape text'), initial ?? o.label ?? '', {
      multi: true,
    });
    if (text !== null) {
      o.set({ label: text, labelSize: font, dirty: true });
      scene.requestRenderAll();
      record();
    }
  }
  scene.on('mouse:dblclick', ({ target }) => editLabel(target));
  stage.onwheel = (e) => {
    if (e.ctrlKey) {
      e.preventDefault();
      zoom(scale * (e.deltaY < 0 ? 1.1 : 1 / 1.1));
    }
  };
  d.onkeydown = guard(async (e) => {
    const o = scene.getActiveObject();
    if (o?.isEditing) {
      if (e.ctrlKey && e.key === 'Enter') o.exitEditing();
      return;
    }
    if (e.target.matches('input,textarea,select') || document.querySelector('dialog:last-of-type') !== d)
      return;
    if (e.key === 'Delete') remove();
    else if (e.ctrlKey && e.key.toLowerCase() === 'z') {
      e.preventDefault();
      await restore(e.shiftKey ? future : history, e.shiftKey ? history : future);
    } else if (e.ctrlKey && e.key === '0') {
      e.preventDefault();
      fit();
    } else if (o && e.key.length === 1 && !e.ctrlKey && !e.metaKey) {
      await editLabel(o, e.key);
    }
  });
  d.addEventListener('close', () => {
    scene.getActiveObject()?.exitEditing?.();
    record();
    scene.dispose();
    refresh();
  });
  setTool('select');
  fit();
  scene.requestRenderAll();
}
