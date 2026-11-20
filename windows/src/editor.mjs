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
  util,
  FabricObject,
  classRegistry,
} from '../assets/fabric.mjs';
import { S, T, el, btn, action, icon, iconButton, modal, pageLabel, save, guard } from './ui.mjs';
import { renderCrop } from './reader.mjs';
FabricObject.customProperties = ['label', 'labelSize', 'arrow', 'minimumBoxHeight'];
function shapeLabel(ctx, o) {
  if (!o.label) return;
  ctx.save();
  ctx.fillStyle = o.stroke || '#161616';
  const font = o.labelSize || 24;
  ctx.font = font + 'px "Segoe UI", sans-serif';
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  const inset = o instanceof Ellipse ? 0.72 : 0.94;
  const w = Math.max(1, o.width * inset - 4),
    h = Math.max(1, o.height * inset);
  const lines = [];
  for (const paragraph of o.label.split('\n')) {
    let line = '';
    for (const ch of paragraph) {
      if (line && ctx.measureText(line + ch).width > w) {
        lines.push(line);
        line = '';
      }
      line += ch;
    }
    lines.push(line);
  }
  ctx.beginPath();
  ctx.rect(-w / 2, -h / 2, w, h);
  ctx.clip();
  lines.forEach((line, i) => ctx.fillText(line, 0, (i - (lines.length - 1) / 2) * font * 1.2));
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
// Resize the frame independently of its type size, including after reopening.
class NoteTextBox extends Textbox {
  static type = 'FolioTextBox';
  static createControls() {
    const result = super.createControls();
    for (const control of Object.values(result.controls)) {
      if ((!control.x && !control.y) || control.actionName === 'rotate') continue;
      control.actionName = 'resizing';
      control.actionHandler = controlsUtils.wrapWithFixedAnchor((event, transform, x, y) => {
        const widthChanged = control.x && controlsUtils.changeObjectWidth(event, transform, x, y);
        const heightChanged = control.y && controlsUtils.changeObjectHeight(event, transform, x, y);
        const box = transform.target;
        if (heightChanged) box.minimumBoxHeight = box.height;
        box.initDimensions();
        return !!(widthChanged || heightChanged);
      });
    }
    return result;
  }
  initDimensions() {
    super.initDimensions();
    this.height = Math.max(this.height || 0, this.minimumBoxHeight || 0);
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
for (const cls of [LabelRect, LabelEllipse, ArrowLine, NoteTextBox]) classRegistry.setClass(cls);
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
  const rotation = S.state.rotations[card.anchors[0].page] || 0;
  const base = await rawPin(card, 1800, rotation);
  const oldSize = card.drawingSize || dimensions(base);
  const angle = card.drawing ? (rotation - (card.rotation || 0) + 360) % 360 : 0;
  const size = angle % 180 ? { width: oldSize.height, height: oldSize.width } : oldSize;
  const surface = el('canvas'),
    paper = el('img', { class: 'markupPaper', src: base.toDataURL(), alt: '', draggable: false });
  const textFrame = el('div', { class: 'markupTextFrame', hidden: true });
  const stage = el('div', { class: 'markupStage', tabIndex: 0 }, paper, surface, textFrame);
  const toolStrip = el('div', { class: 'markupTools' }),
    properties = el('div', { class: 'markupProperties' });
  const foot = el('footer', { class: 'markupFooter' });
  const d = modal(card.title || T('图表便签', 'Pinned figure'), toolStrip, properties, stage, foot);
  d.classList.add('markupSheet');
  const done = btn(
    T('完成', 'Done'),
    () => {
      endText();
      d.close();
    },
    'doneButton'
  );
  const copy = action('copy', T('复制图片', 'Copy image'), async () => {
    endText();
    await folio.copyImage((await artwork(card)).toDataURL());
  });
  const heading = d.querySelector('h2');
  d.querySelector('.dialogHead').replaceChildren(
    el('div', { class: 'markupTitleIcon' }, icon('pen-line')),
    el(
      'div',
      { class: 'markupHeading' },
      heading,
      el('small', { textContent: pageLabel(card.anchors[0].page) })
    ),
    el('span', { class: 'space' }),
    copy,
    done
  );
  const scene = new Canvas(surface, {
    preserveObjectStacking: true,
    selection: false,
    enablePointerEvents: true,
    targetFindTolerance: 5,
    selectionColor: 'rgba(70,128,225,.08)',
    selectionBorderColor: '#6096e7',
  });
  let tool = 'select',
    start,
    draft,
    textEditor,
    panning,
    spaceDown = false,
    restoring = false;
  let scale = 1,
    tx = 0,
    ty = 0,
    fitted = true;
  const history = [],
    future = [],
    buttons = new Map();
  const defaults = { color: '#d74b42', width: 4, dash: false, font: 26 };
  const names = [
    ['select', 'mouse-pointer-2', T('选择', 'Select'), 'V'],
    ['pen', 'pencil', T('画笔', 'Pen'), 'P'],
    ['line', 'slash', T('直线', 'Line'), 'L'],
    ['arrow', 'move-up-right', T('箭头', 'Arrow'), 'A'],
    ['rect', 'square', T('矩形', 'Rectangle'), 'R'],
    ['ellipse', 'circle', T('椭圆', 'Ellipse'), 'O'],
    ['text', 'type', T('文本框', 'Text'), 'T'],
  ];
  const toolsGroup = el('div', { class: 'markupSegments' });
  for (const [key, symbol, name, shortcut] of names) {
    const b = iconButton(symbol, name, () => setTool(key));
    b.title = name + ' (' + shortcut + ')';
    b.append(el('span', { textContent: name }));
    toolsGroup.append(b);
    buttons.set(key, b);
  }
  const undo = iconButton('undo-2', T('撤销', 'Undo'), () => restore(history, future));
  const redo = iconButton('redo-2', T('重做', 'Redo'), () => restore(future, history));
  toolStrip.append(toolsGroup, el('span', { class: 'space' }), undo, redo);
  const colorNames = [
    [T('朱红', 'Red'), '#d74b42'],
    [T('琥珀', 'Amber'), '#d19319'],
    [T('蓝色', 'Blue'), '#3579df'],
    [T('紫色', 'Violet'), '#8b60bb'],
    [T('墨黑', 'Ink'), '#303135'],
  ];
  const swatches = el('div', { class: 'inkSwatches' });
  for (const [name, value] of colorNames) {
    const b = iconButton('check', name, () => change('color', value));
    b.classList.add('swatch');
    b.style.setProperty('--ink', value);
    b.dataset.color = value;
    swatches.append(b);
  }
  const custom = el('input', {
    type: 'color',
    title: T('自定义颜色', 'Custom color'),
    onchange: (e) => change('color', e.target.value),
  });
  swatches.append(el('label', { class: 'customInk', title: custom.title }, icon('palette'), custom));
  const number = (name, min, max, prop) => {
    const input = el('input', {
      type: 'number',
      min,
      max,
      title: name,
      onchange: () => {
        if (!Number.isFinite(input.valueAsNumber)) return sync();
        change(prop, Math.max(min, Math.min(max, input.valueAsNumber)));
      },
    });
    input.onkeydown = (e) => {
      if (e.key === 'Enter' && textEditor) {
        e.preventDefault();
        textEditor.input.focus();
      }
    };
    return el('label', { class: 'markupField' }, el('span', { textContent: name }), input);
  };
  const lineWidth = number(T('线宽', 'Width'), 1, 32, 'width'),
    fontSize = number(T('字号', 'Type size'), 8, 160, 'font');
  const dash = el(
    'select',
    { title: T('线型', 'Line style'), onchange: (e) => change('dash', e.target.value === 'dash') },
    el('option', { value: 'solid', textContent: T('实线', 'Solid') }),
    el('option', { value: 'dash', textContent: T('虚线', 'Dashed') })
  );
  const labelButton = action('text-cursor-input', T('形状文字', 'Shape text'), () =>
    editText(scene.getActiveObject())
  );
  const remove = iconButton('trash-2', T('删除标注', 'Delete markup'), () => {
    endText();
    const objects = scene.getActiveObjects();
    if (!objects.length) return;
    scene.discardActiveObject();
    scene.remove(...objects);
    scene.requestRenderAll();
    record();
    sync();
  });
  const hint = el('span', { class: 'markupHint' });
  properties.append(
    hint,
    swatches,
    lineWidth,
    dash,
    fontSize,
    labelButton,
    el('span', { class: 'space' }),
    remove
  );
  const zoomLabel = el('output'),
    status = el('span', { class: 'markupStatus' });
  foot.append(
    icon('hand'),
    status,
    el('span', { class: 'space' }),
    iconButton('minus', T('缩小标注', 'Zoom out of figure'), () => zoom(scale / 1.25)),
    zoomLabel,
    iconButton('plus', T('放大标注', 'Zoom into figure'), () => zoom(scale * 1.25)),
    el('span', { class: 'railDivider' }),
    action('scan', T('全图', 'Fit'), fit)
  );
  function prepare(o) {
    o.set({
      cornerStyle: 'circle',
      cornerSize: 9,
      touchCornerSize: 22,
      transparentCorners: false,
      cornerColor: '#fff',
      cornerStrokeColor: '#397bd6',
      borderColor: '#397bd6',
      borderScaleFactor: 1.3,
    });
    if (o instanceof ArrowLine) {
      o.controls = controlsUtils.createPolyControls(o);
      o.hasBorders = false;
      o.perPixelTargetFind = true;
    }
    // Text entry uses the visible native field inside this dialog, including IME composition.
    if (o instanceof Textbox) o.editable = false;
  }
  if (card.drawing) {
    await scene.loadFromJSON(card.drawing);
    const matrix = {
      90: [0, 1, -1, 0, oldSize.height, 0],
      180: [-1, 0, 0, -1, oldSize.width, oldSize.height],
      270: [0, -1, 1, 0, 0, oldSize.width],
    }[angle];
    for (const o of scene.getObjects()) {
      if (matrix) util.addTransformToObject(o, matrix);
      prepare(o);
      o.setCoords();
    }
  }
  let last = scene.toJSON();
  function persist(json) {
    last = json;
    card.drawing = json;
    card.drawingSize = size;
    card.rotation = rotation;
    save();
    undo.disabled = !history.length;
    redo.disabled = !future.length;
  }
  function record() {
    if (restoring || draft || textEditor) return;
    const json = scene.toJSON();
    if (JSON.stringify(json) === JSON.stringify(last)) return;
    history.push(last);
    if (history.length > 80) history.shift();
    future.length = 0;
    persist(json);
  }
  async function restore(from, to) {
    endText();
    if (!from.length || restoring) return;
    restoring = true;
    try {
      scene.discardActiveObject();
      const next = from[from.length - 1];
      await scene.loadFromJSON(next);
      scene.getObjects().forEach(prepare);
      to.push(last);
      from.pop();
      persist(next);
      setTool('select');
      view();
    } finally {
      restoring = false;
    }
  }
  function view() {
    scene.setViewportTransform([scale, 0, 0, scale, tx, ty]);
    Object.assign(paper.style, {
      width: size.width + 'px',
      height: size.height + 'px',
      transform: 'translate(' + tx + 'px,' + ty + 'px) scale(' + scale + ')',
    });
    zoomLabel.value = Math.round((scale / fitScale()) * 100) + '%';
    scene.requestRenderAll();
    positionField();
  }
  const fitScale = () =>
    Math.max(
      0.01,
      Math.min((stage.clientWidth - 40) / size.width, (stage.clientHeight - 40) / size.height)
    );
  function fit() {
    const w = stage.clientWidth,
      h = stage.clientHeight;
    scale = fitScale();
    tx = (w - size.width * scale) / 2;
    ty = (h - size.height * scale) / 2;
    fitted = true;
    view();
  }
  function zoom(value, x = stage.clientWidth / 2, y = stage.clientHeight / 2) {
    const fitValue = fitScale(),
      next = Math.min(fitValue * 8, Math.max(fitValue * 0.25, value)),
      factor = next / scale;
    tx = x - (x - tx) * factor;
    ty = y - (y - ty) * factor;
    scale = next;
    fitted = false;
    view();
  }
  const resize = new ResizeObserver(() => {
    const w = stage.clientWidth,
      h = stage.clientHeight;
    if (!w || !h || !d.open) return;
    const dx = (w - scene.width) / 2,
      dy = (h - scene.height) / 2;
    scene.setDimensions({ width: w, height: h });
    if (fitted) fit();
    else {
      tx += dx;
      ty += dy;
      view();
    }
  });
  resize.observe(stage);
  function brush() {
    if (!scene.isDrawingMode) return;
    const b = new PencilBrush(scene);
    b.color = defaults.color;
    b.width = defaults.width;
    b.strokeDashArray = defaults.dash ? [b.width * 3, b.width * 2] : null;
    scene.freeDrawingBrush = b;
  }
  function setTool(value) {
    endText();
    if (start) {
      if (draft) scene.remove(draft);
      textFrame.hidden = true;
      start = null;
      draft = null;
    }
    if (value !== 'select') scene.discardActiveObject();
    tool = value;
    scene.isDrawingMode = tool === 'pen';
    scene.skipTargetFind = tool !== 'select';
    scene.defaultCursor = tool === 'select' ? 'default' : 'crosshair';
    for (const [k, b] of buttons) {
      b.classList.toggle('active', k === tool);
      b.setAttribute('aria-pressed', String(k === tool));
    }
    brush();
    sync();
    scene.requestRenderAll();
    stage.focus({ preventScroll: true });
  }
  const isLabel = (o) => o instanceof LabelRect || o instanceof LabelEllipse;
  function sync() {
    const o = scene.getActiveObject(),
      text = o instanceof Textbox || tool === 'text',
      label = isLabel(o) || ['rect', 'ellipse'].includes(tool);
    const idle = tool === 'select' && !o;
    const color = o ? (o instanceof Textbox ? o.fill : o.stroke) : defaults.color;
    swatches.hidden = idle;
    lineWidth.hidden = idle || text;
    dash.hidden = idle || text;
    fontSize.hidden = idle || (!text && !label);
    labelButton.hidden = !isLabel(o) && !(o instanceof Textbox);
    labelButton.lastChild.textContent =
      o instanceof Textbox ? T('编辑文字', 'Edit text') : T('形状文字', 'Shape text');
    remove.hidden = !o;
    hint.hidden = !idle;
    hint.textContent = T(
      '选择标注可调整样式，或从上方选择绘图工具。',
      'Select a mark to change its style, or choose a drawing tool.'
    );
    for (const b of swatches.querySelectorAll('button'))
      b.setAttribute('aria-pressed', String(b.dataset.color === color));
    custom.value = /^#[0-9a-f]{6}$/i.test(color) ? color : defaults.color;
    lineWidth.lastChild.value = o?.strokeWidth ?? defaults.width;
    fontSize.lastChild.value = (o instanceof Textbox ? o.fontSize : o?.labelSize) ?? defaults.font;
    dash.value = (o ? o.strokeDashArray?.length : defaults.dash) ? 'dash' : 'solid';
    undo.disabled = !history.length;
    redo.disabled = !future.length;
    status.textContent =
      tool === 'select'
        ? T('空格拖动平移 · Ctrl + 滚轮缩放', 'Space + drag to pan · Ctrl + scroll to zoom')
        : tool === 'text'
          ? T('单击输入文字，或拖出文本框', 'Click to type, or drag to size a text box')
          : tool === 'pen'
            ? T('按住并拖动绘制笔迹', 'Drag to draw a stroke')
            : ['rect', 'ellipse'].includes(tool)
              ? T('拖动绘制 · 按住 Shift 保持等宽高', 'Drag to draw · Hold Shift for equal sides')
              : T('拖动绘制 · 按住 Shift 锁定角度', 'Drag to draw · Hold Shift to snap the angle');
    if (o instanceof ArrowLine)
      status.textContent = T(
        '拖动端点调整方向和长度',
        'Drag an endpoint to change direction and length'
      );
    else if (isLabel(o))
      status.textContent = T(
        '拖动手柄调整大小 · 双击输入文字',
        'Drag a handle to resize · Double-click to add text'
      );
    else if (o instanceof Textbox)
      status.textContent = T(
        '拖动手柄调整文本框 · 双击编辑文字',
        'Drag handles to resize the box · Double-click to edit text'
      );
    else if (o)
      status.textContent = T(
        '拖动笔迹移动 · 拖动手柄缩放',
        'Drag the stroke to move it · Drag handles to resize'
      );
  }
  function change(key, value) {
    const o = scene.getActiveObject();
    if (!o) {
      defaults[key] = value;
      brush();
    } else {
      if (key === 'color') o.set(o instanceof Textbox ? 'fill' : 'stroke', value);
      if (key === 'font') o.set(o instanceof Textbox ? 'fontSize' : 'labelSize', value);
      if (key === 'width') o.set('strokeWidth', value);
      if (key === 'dash' || (key === 'width' && o.strokeDashArray))
        o.set(
          'strokeDashArray',
          (key === 'dash' ? value : true) ? [o.strokeWidth * 3, o.strokeWidth * 2] : null
        );
      o.set('dirty', true);
      o.setCoords();
      record();
    }
    sync();
    positionField();
    if (textEditor && document.activeElement?.matches('.swatch'))
      textEditor.input.focus({ preventScroll: true });
    scene.requestRenderAll();
  }
  function positionField() {
    if (!textEditor) return;
    const { o, input } = textEditor;
    const box = o instanceof Textbox;
    const matrix = util.multiplyTransformMatrices(scene.viewportTransform, o.calcTransformMatrix());
    Object.assign(input.style, {
      width: o.width + 'px',
      height: o.height + 'px',
      fontSize: (box ? o.fontSize : o.labelSize || 24) + 'px',
      color: box ? o.fill : o.stroke,
      transform:
        'matrix(' + matrix.join(',') + ') translate(' + -o.width / 2 + 'px,' + -o.height / 2 + 'px)',
    });
    if (box) {
      input.style.fontFamily = o.fontFamily;
      input.style.lineHeight = String(o.lineHeight);
      input.style.textAlign = o.textAlign;
      input.style.fontStyle = o.fontStyle;
      input.style.fontWeight = String(o.fontWeight);
      input.style.height = Math.max(o.height, input.scrollHeight) + 'px';
    }
  }
  function editText(o, event, created = false) {
    if (!(o instanceof Textbox || isLabel(o))) return;
    if (textEditor?.o === o) {
      textEditor.input.focus();
      return;
    }
    endText();
    const box = o instanceof Textbox;
    const title = box ? T('文本框内容', 'Text box content') : T('形状文字', 'Shape text');
    const input = el('textarea', {
      class: box ? 'markupTextInput' : 'shapeLabelInput',
      value: (box ? o.text : o.label) || '',
      title,
      spellcheck: false,
      placeholder: box ? T('输入文字…', 'Type here…') : '',
    });
    input.setAttribute('aria-label', title);
    textEditor = {
      o,
      input,
      created,
      originalStyle: box
        ? { fill: o.fill, fontSize: o.fontSize }
        : { stroke: o.stroke, labelSize: o.labelSize },
    };
    stage.append(input);
    positionField();
    input.focus({ preventScroll: true });
    if (box && event && o.text) {
      const index = o.getSelectionStartFromPointer(event);
      const offset = o.graphemeSplit(o.text).slice(0, index).join('').length;
      input.setSelectionRange(offset, offset);
    } else if (box) input.setSelectionRange(input.value.length, input.value.length);
    else input.select();
    status.textContent = T(
      'Enter 换行 · Ctrl+Enter 完成 · Esc 取消',
      'Enter for a new line · Ctrl+Enter to finish · Esc to cancel'
    );
    input.oninput = positionField;
    input.onblur = (e) => {
      if (!properties.contains(e.relatedTarget)) endText();
    };
    input.onkeydown = (e) => {
      e.stopPropagation();
      if (e.isComposing || e.keyCode === 229) return;
      if (e.key === 'Escape' || (e.key === 'Enter' && (e.ctrlKey || e.metaKey))) {
        e.preventDefault();
        endText(e.key !== 'Escape');
        stage.focus();
      }
    };
  }
  function endText(commit = true) {
    if (!textEditor) return;
    const { o, input, created, originalStyle } = textEditor;
    textEditor = null;
    input.onblur = null;
    const text = input.value;
    input.remove();
    if (!commit) o.set(originalStyle);
    if (o instanceof Textbox) {
      if ((created && !commit) || (commit && !text.trim())) {
        if (scene.getActiveObject() === o) scene.discardActiveObject();
        scene.remove(o);
      } else if (commit && o.text !== text) {
        o.set({ splitByGrapheme: true, text });
        o.initDimensions();
      }
    } else if (commit) o.set({ label: text, dirty: true });
    o.setCoords();
    scene.requestRenderAll();
    record();
    sync();
  }
  d.addEventListener('cancel', (e) => {
    if (textEditor) e.preventDefault();
  });
  properties.addEventListener('focusout', (e) => {
    if (textEditor && e.relatedTarget !== textEditor.input && !properties.contains(e.relatedTarget))
      endText();
  });
  stage.addEventListener(
    'pointerdown',
    (e) => {
      if (textEditor && e.target !== textEditor.input) endText();
    },
    true
  );
  function inside(p) {
    return p.x >= 0 && p.y >= 0 && p.x <= size.width && p.y <= size.height;
  }
  function endpoint(p, shift) {
    let dx = p.x - start.x,
      dy = p.y - start.y;
    if (shift && ['rect', 'ellipse'].includes(tool)) {
      const side = Math.max(Math.abs(dx), Math.abs(dy));
      dx = (dx < 0 ? -1 : 1) * side;
      dy = (dy < 0 ? -1 : 1) * side;
    } else if (shift && ['line', 'arrow'].includes(tool)) {
      const angle = (Math.round(Math.atan2(dy, dx) / (Math.PI / 4)) * Math.PI) / 4,
        len = Math.hypot(dx, dy);
      dx = Math.cos(angle) * len;
      dy = Math.sin(angle) * len;
    }
    return new Point(
      Math.max(0, Math.min(size.width, start.x + dx)),
      Math.max(0, Math.min(size.height, start.y + dy))
    );
  }
  function updateDraft(p) {
    const left = Math.min(start.x, p.x),
      top = Math.min(start.y, p.y),
      width = Math.max(1, Math.abs(p.x - start.x)),
      height = Math.max(1, Math.abs(p.y - start.y));
    if (!draft) {
      const style = {
        originX: 'left',
        originY: 'top',
        fill: 'transparent',
        stroke: defaults.color,
        strokeWidth: defaults.width,
        strokeUniform: true,
        strokeDashArray: defaults.dash ? [defaults.width * 3, defaults.width * 2] : null,
        labelSize: defaults.font,
      };
      if (tool === 'rect') draft = new LabelRect(style);
      else if (tool === 'ellipse') draft = new LabelEllipse(style);
      else if (tool === 'text')
        draft = new NoteTextBox('', {
          ...style,
          fill: defaults.color,
          stroke: null,
          strokeWidth: 0,
          splitByGrapheme: true,
          fontSize: defaults.font,
          fontFamily: 'Segoe UI, sans-serif',
        });
      else draft = new ArrowLine([start, p], { ...style, fill: null, arrow: tool === 'arrow' });
      prepare(draft);
      scene.add(draft);
    }
    if (draft instanceof ArrowLine) {
      draft.set('points', [start, p]);
      draft.setBoundingBox(true);
    } else if (tool === 'ellipse') draft.set({ left, top, rx: width / 2, ry: height / 2 });
    else if (tool === 'text') {
      draft.set({ left, top, width: Math.max(25, width), minimumBoxHeight: height });
      draft.initDimensions();
      const matrix = util.multiplyTransformMatrices(
        scene.viewportTransform,
        draft.calcTransformMatrix()
      );
      Object.assign(textFrame.style, {
        width: draft.width + 'px',
        height: draft.height + 'px',
        transform: 'matrix(' + matrix.join(',') + ') translate(-50%,-50%)',
      });
      textFrame.hidden = false;
    } else draft.set({ left, top, width, height });
    draft.setCoords();
    scene.requestRenderAll();
  }
  scene.on('mouse:down', ({ scenePoint }) => {
    if (['select', 'pen'].includes(tool) || !inside(scenePoint) || restoring) return;
    start = scenePoint;
  });
  scene.on('mouse:move', ({ scenePoint, e }) => {
    if (!start || (!draft && scenePoint.distanceFrom(start) * scale < 3)) return;
    updateDraft(endpoint(scenePoint, e.shiftKey));
  });
  scene.on('mouse:up', ({ scenePoint, e }) => {
    if (!start) return;
    if (tool === 'text' && !draft) {
      const existing = [...scene.getObjects()]
        .reverse()
        .find((o) => o instanceof Textbox && o.containsPoint(start));
      if (existing) {
        start = null;
        setTool('select');
        scene.setActiveObject(existing);
        editText(existing, e);
        scene.requestRenderAll();
        return;
      }
      const width = Math.min(size.width, 160 / scale),
        height = Math.min(size.height, defaults.font * 1.35);
      start = new Point(Math.min(start.x, size.width - width), Math.min(start.y, size.height - height));
      updateDraft(new Point(start.x + width, start.y + height));
    } else if (draft) updateDraft(endpoint(scenePoint, e.shiftKey));
    const o = draft;
    textFrame.hidden = true;
    draft = null;
    start = null;
    if (!o) return;
    setTool('select');
    scene.setActiveObject(o);
    if (o instanceof Textbox) editText(o, null, true);
    else record();
    scene.requestRenderAll();
  });
  scene.on('path:created', ({ path }) => {
    prepare(path);
    setTool('select');
    scene.setActiveObject(path);
    record();
    scene.requestRenderAll();
  });
  scene.on('object:modified', record);
  for (const event of ['selection:created', 'selection:updated', 'selection:cleared'])
    scene.on(event, sync);
  scene.on('mouse:dblclick', ({ target, e }) => editText(target, e));
  stage.addEventListener(
    'wheel',
    (e) => {
      if (e.target.closest('textarea')) return;
      e.preventDefault();
      const r = stage.getBoundingClientRect();
      if (e.ctrlKey || e.metaKey)
        zoom(
          scale * Math.exp(-Math.max(-150, Math.min(150, e.deltaY)) * 0.008),
          e.clientX - r.left,
          e.clientY - r.top
        );
      else {
        tx -= e.deltaX;
        ty -= e.deltaY;
        fitted = false;
        view();
      }
    },
    { passive: false }
  );
  stage.addEventListener(
    'pointerdown',
    (e) => {
      if (e.target.closest('textarea')) return;
      if ((spaceDown || e.button === 1) && !start) {
        e.preventDefault();
        e.stopImmediatePropagation();
        stage.setPointerCapture(e.pointerId);
        panning = { x: e.clientX, y: e.clientY, tx, ty };
        stage.classList.add('panning');
      } else if (tool === 'pen' && !inside(scene.getScenePoint(e))) e.stopImmediatePropagation();
    },
    true
  );
  function panToPointer(e) {
    if (!panning) return;
    tx = panning.tx + e.clientX - panning.x;
    ty = panning.ty + e.clientY - panning.y;
    fitted = false;
    view();
  }
  stage.addEventListener('pointermove', panToPointer);
  stage.addEventListener('pointerup', panToPointer);
  stage.addEventListener('lostpointercapture', () => {
    panning = null;
    stage.classList.remove('panning');
  });
  d.onkeydown = guard(async (e) => {
    const o = scene.getActiveObject(),
      mod = e.ctrlKey || e.metaKey,
      key = e.key.toLowerCase();
    if (e.target.matches('input,textarea,select')) return;
    if (e.code === 'Space' && !e.target.matches('button')) {
      e.preventDefault();
      spaceDown = true;
      stage.classList.add('canPan');
      return;
    }
    if (key === 'escape' && start) {
      e.preventDefault();
      if (draft) scene.remove(draft);
      textFrame.hidden = true;
      draft = null;
      start = null;
      scene.requestRenderAll();
      return;
    }
    if (key === 'delete' || key === 'backspace') {
      e.preventDefault();
      remove.click();
    } else if (mod && ['z', 'y'].includes(key)) {
      e.preventDefault();
      const forward = key === 'y' || e.shiftKey;
      await restore(forward ? future : history, forward ? history : future);
    } else if (mod && key === '0') {
      e.preventDefault();
      fit();
    } else if (mod && ['-', '=', '+'].includes(key)) {
      e.preventDefault();
      zoom(scale * (key === '-' ? 0.8 : 1.25));
    } else if (mod && key === 'c') {
      e.preventDefault();
      copy.click();
    } else if (!mod && (key === 'enter' || key === 'f2') && (isLabel(o) || o instanceof Textbox)) {
      e.preventDefault();
      editText(o);
    } else if (!mod) {
      const item = names.find((n) => n[3].toLowerCase() === key);
      if (item) setTool(item[0]);
    }
  });
  const releaseSpace = () => {
    spaceDown = false;
    stage.classList.remove('canPan');
  };
  d.onkeyup = (e) => {
    if (e.code === 'Space') releaseSpace();
  };
  window.addEventListener('blur', releaseSpace);
  d.addEventListener('close', () => {
    resize.disconnect();
    window.removeEventListener('blur', releaseSpace);
    endText();
    if (draft) {
      scene.remove(draft);
      draft = null;
    }
    record();
    scene.dispose();
    refresh();
  });
  setTool('select');
  stage.focus();
  fit();
}
