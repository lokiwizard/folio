// Runs against either the development runtime or a freshly installed Windows EXE.
// Dialogs choose files in the temporary directory. PDF content is never uploaded.
const { _electron } = require('playwright-core');
const assert = require('node:assert/strict'),
  fs = require('node:fs/promises'),
  os = require('node:os'),
  path = require('node:path');
const { createHash } = require('node:crypto');
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function eventually(fn) {
  let failure;
  for (let i = 0; i < 80; i++) {
    try {
      return await fn();
    } catch (e) {
      failure = e;
      await delay(100);
    }
  }
  throw failure;
}
async function run() {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'folio-ui-')),
    root = path.resolve(__dirname, '..'),
    fixture = path.join(root, '../Tests/Fixtures/embedded-highlights.pdf');
  const pdf = path.join(dir, '双栏 test.pdf');
  await fs.copyFile(fixture, pdf);
  const original = await fs.readFile(pdf),
    id = createHash('sha256').update(original).digest('hex');
  const profile = path.join(dir, 'profile'),
    statePath = path.join(profile, 'Folio', id + '.json');
  const state = async () => JSON.parse(await fs.readFile(statePath, 'utf8'));
  const readState = async (check) => eventually(async () => check(await state()));
  const app = await _electron.launch({
    executablePath: process.env.FOLIO_TEST_EXE || require('electron'),
    args: ['--user-data-dir=' + profile, ...(process.env.FOLIO_TEST_EXE ? [] : [root]), pdf],
    timeout: 35000,
  });
  let win;
  try {
    win = await app.firstWindow();
    const errors = [];
    win.on('pageerror', (err) => errors.push(err.message));
    win.on('console', (m) => {
      if (m.type() === 'error') {
        console.error('RENDERER', m.text().slice(0, 600));
        errors.push(m.text());
      }
    });
    win.setDefaultTimeout(12000);
    await app.evaluate(({ dialog }, dir) => {
      dialog.showSaveDialog = async (_, options) => ({
        canceled: false,
        filePath: dir + '/' + (options.defaultPath.endsWith('.md') ? 'notes.md' : 'pages.pdf'),
      });
    }, dir);
    const button = (name) => win.getByRole('button', { name, exact: true });
    await win.waitForSelector('#desk:not([hidden])');
    await win.waitForSelector('.textLayer span');
    await readState((s) => {
      assert.equal(s.cards.filter((c) => c.source).length, 2);
      assert.equal(s.cards.find((c) => c.source?.startsWith('1/')).text, 'Alpha result\nBeta result');
    });
    console.log('PASS opened PDF, imported both original highlights and extracted two-column text');
    await button('批注').click();
    await win.locator('.folioMark').first().click();
    await button('取消高亮').click();
    await readState((s) => assert.equal(s.cards.length, 1));
    await button('撤销删除').click();
    await readState((s) => assert.equal(s.cards.length, 2));
    const span = win.locator('.textLayer span').filter({ hasText: 'Unrelated text' }).first();
    const lineBox = await span.boundingBox();
    await win.mouse.move(lineBox.x + 1, lineBox.y + lineBox.height / 2);
    await win.mouse.down();
    await win.mouse.move(lineBox.x + lineBox.width - 1, lineBox.y + lineBox.height / 2, { steps: 12 });
    await win.mouse.up();
    await button('默认高亮').click();
    await readState((s) => assert.ok(s.cards.some((c) => !c.source && c.text.includes('nrelated'))));
    const manual = win.locator('.card').filter({ hasText: 'nrelated' });
    await manual.getByRole('button', { name: '卡片操作' }).click();
    await button('删除').click();
    await readState((s) => assert.equal(s.cards.length, 2));
    await win.locator('#clip').click();
    const page = win.locator('.page[data-page-number="1"]'),
      box = await page.boundingBox();
    await win.mouse.move(box.x + box.width * 0.09, box.y + box.height * 0.1);
    await win.mouse.down();
    await win.mouse.move(box.x + box.width * 0.8, box.y + box.height * 0.55, { steps: 9 });
    await win.mouse.up();
    await button('固定').click();
    const pin = win.locator('.card img');
    await pin.waitFor();
    await win.waitForFunction(() => document.querySelector('.card img')?.naturalWidth > 0);
    await pin.click();
    await button('矩形').click();
    const draw = win.locator('.upper-canvas');
    const surface = await draw.boundingBox();
    await win.mouse.move(surface.x + surface.width * 0.15, surface.y + surface.height * 0.2);
    await win.mouse.down();
    await win.mouse.move(surface.x + surface.width * 0.7, surface.y + surface.height * 0.7, {
      steps: 7,
    });
    await win.mouse.up();
    await readState((s) =>
      assert.equal(s.cards.find((c) => c.kind === 'pin').drawing.objects.length, 1)
    );
    await win.locator('dialog .dialogHead button').click();
    await win.waitForSelector('dialog', { state: 'detached' });
    await win.locator('#display').click();
    await button('旋转').click();
    await readState((s) => assert.equal(s.rotations[1], 90));
    await win.locator('#zoom').selectOption('page-fit');
    await win.locator('#page').fill('2');
    await win.locator('#page').press('Enter');
    await win.locator('.card').getByRole('button', { name: '第 1 页' }).click();
    await readState((s) => assert.equal(s.page, 1));
    await win.keyboard.press('Control+d');
    await win.locator('dialog input').fill('Figure A');
    await button('确定').click();
    await readState((s) => assert.equal(s.bookmarks[0].name, 'Figure A'));
    await win.keyboard.press('Control+f');
    await win.locator('#query').fill('Alpha');
    await win.waitForFunction(() => document.querySelector('#matches').textContent.includes('/ 1'));
    await win.locator('#closeFind').click();
    console.log('PASS deletion/undo, clip, draw, zoom, rotate, source navigation, bookmarks and search');
    // Send the real print layout through Chromium's PDF printer in place of a
    // physical printer dialog on the unattended runner.
    await app.evaluate(({BrowserWindow})=>{
      const wc=BrowserWindow.getAllWindows()[0].webContents;
      wc.print=async(_options,callback)=>{
        try{const data=await wc.printToPDF({printBackground:true});globalThis.__folioPrint=data.subarray(0,5).toString();callback(true,'');}
        catch(error){callback(false,error.message);}
      };
    });
    await win.locator('#more').click();
    await button('打印当前页').click();
    await eventually(async()=>assert.equal(await app.evaluate(()=>globalThis.__folioPrint),'%PDF-'));
    if(process.env.FOLIO_SCREENSHOT_DIR){
      await fs.mkdir(process.env.FOLIO_SCREENSHOT_DIR,{recursive:true});
      await win.screenshot({path:path.join(process.env.FOLIO_SCREENSHOT_DIR,'Folio-Windows-reading.png')});
    }
    await win.locator('#more').click();
    await button('导出 Markdown 笔记…').click();
    const md = await eventually(() => fs.readFile(path.join(dir, 'notes.md'), 'utf8'));
    assert.match(md, /> Alpha result\n> Beta result/);
    const imgPath = md.match(/!\[\]\((figures-[^\)]+\.png)\)/)[1];
    assert.ok((await fs.stat(path.join(dir, imgPath))).size > 100);
    await win.locator('#more').click();
    await button('提取页面为 PDF…').click();
    await win.locator('dialog input').fill('2, 1–2');
    await button('确定').click();
    await eventually(async () => assert.ok((await fs.stat(path.join(dir, 'pages.pdf'))).size > 500));
    await win.locator('#more').click();
    await button('返回最近打开').click();
    await win.locator('#recents button').first().click();
    await win.waitForSelector('.card img');
    await readState((s) => {
      assert.equal(s.cards.length, 3);
      assert.equal(s.rotations[1], 90);
    });
    await win.locator('#more').click();
    await button('界面语言').click();
    await win.locator('#more').click();
    await button('Settings…').click();
    await button('Dark').click();
    await win.waitForFunction(() => document.documentElement.dataset.dark === 'true');
    await win.locator('dialog .dialogHead button').click();
    console.log('PASS Markdown + PNG, reordered PDF, saved state and language/appearance controls');
    await win.locator('#ask').click();
    await button('Prompts').click();
    await win.locator('dialog textarea').fill('Explain this figure');
    await button('OK').click();
    await button('Explain this figure').click();
    assert.equal(await win.locator('#question').inputValue(), 'Explain this figure');
    if (process.platform === 'win32') {
      await win.locator('#more').click();
      await button('Settings…').click();
      await button('AI services').click();
      await win.locator('dialog input[type=url]').fill('https://folio-test.invalid/v1');
      await win.locator('dialog input:not([type])').fill('fixture-model');
      await win.locator('dialog input[type=password]').fill('folio-fixture-dummy-key');
      await button('Save and use').click();
      await win.waitForFunction(() =>
        document.querySelector('dialog input[type=password]')?.placeholder.includes('saved')
      );
      await win.locator('dialog .dialogHead button').click();
      const ciphertext = await fs.readFile(path.join(profile, 'Folio', 'credentials.json'), 'utf8');
      assert.ok(!ciphertext.includes('folio-fixture-dummy-key'));
      await app.evaluate(() => {
        globalThis.fetch = async (url, options) => {
          if (url !== 'https://folio-test.invalid/v1/chat/completions')
            throw Error('Unexpected destination');
          if (options.headers.Authorization !== 'Bearer folio-fixture-dummy-key')
            throw Error('Credential mismatch');
          const body = JSON.parse(options.body);
          globalThis.__folioTestRequest = body;
          return new Response(
            'data: ' +
              JSON.stringify({ choices: [{ delta: { content: '**Result** $x^2$' } }] }) +
              '\n\ndata: [DONE]\n\n',
            { headers: { 'content-type': 'text/event-stream' } }
          );
        };
      });
      await button('Figures').click();
      await win.locator('.card').dragTo(win.locator('#ask'));
      await win.locator('#question').fill('Explain the reference');
      const files = win.locator('.composer input[type=file]');
      await files.setInputFiles({
        name: 'fixture.txt',
        mimeType: 'text/plain',
        buffer: Buffer.from('fixture passage'),
      });
      await win.waitForFunction(() =>
        document.querySelector('.composer')?.innerText.includes('fixture.txt')
      );
      await button('Preview').click();
      await win.locator('dialog img').waitFor();
      await win.locator('dialog .dialogHead button').click();
      await button('Send').click();
      await win.waitForSelector('.message math');
      await readState((s) => assert.match(s.chats[0].turns[0].answer, /Result/));
      const payload = await app.evaluate(() => globalThis.__folioTestRequest);
      assert.match(JSON.stringify(payload), /fixture passage/);
      assert.equal(payload.messages.at(-1).content.filter((p) => p.type === 'image_url').length, 1);
      console.log(
        'PASS Windows credential encryption, drag-to-AI, attachment, preview, streaming, math and chat history'
      );
    }
    // Check encrypted input and the extracted PDF through the real open dialog path.
    const locked = path.join(dir, 'locked.pdf'),
      unlocked = path.join(dir, 'unlocked.pdf');
    const wasm = await WebAssembly.compile(
      await fs.readFile(require.resolve('@jspawn/qpdf-wasm/qpdf.wasm'))
    );
    const qpdf = await require('@jspawn/qpdf-wasm')({
      instantiateWasm(imports, ready) {
        const instance = new WebAssembly.Instance(wasm, imports);
        ready(instance);
        return instance.exports;
      },
    });
    qpdf.FS.writeFile('/in.pdf', original);
    assert.equal(
      qpdf.callMain(['/in.pdf', '--encrypt', 'reader-test', 'owner-test', '256', '--', '/locked.pdf']),
      0
    );
    await fs.writeFile(locked, qpdf.FS.readFile('/locked.pdf'));
    await app.evaluate(
      ({ dialog }, paths) => {
        dialog.showOpenDialog = async () => ({ filePaths: [paths.locked] });
        dialog.showSaveDialog = async () => ({ filePath: paths.unlocked, canceled: false });
      },
      { locked, unlocked }
    );
    await win.keyboard.press('Control+o');
    await win.locator('dialog input[type=password]').fill('reader-test');
    await button('OK').click();
    await win.waitForFunction(() => document.title.startsWith('locked.pdf'));
    await win.locator('#more').click();
    await button('Extract pages to PDF…').click();
    await win.locator('dialog input').fill('2, 1');
    await button('OK').click();
    await eventually(async () => assert.ok((await fs.stat(unlocked)).size > 500));
    await app.evaluate(({ dialog }, out) => {
      dialog.showOpenDialog = async () => ({ filePaths: [out] });
    }, unlocked);
    await win.keyboard.press('Control+o');
    await win.waitForFunction(() => document.title.startsWith('unlocked.pdf'));
    assert.equal(await win.locator('#pageCount').textContent(), '/ 2');
    const extraction = await win.evaluate(async () => {
      const { S } = await import('./ui.mjs');
      const first = await S.doc.getPage(1),
        second = await S.doc.getPage(2);
      return {
        angle: first.rotate,
        empty: !(await first.getTextContent()).items.length,
        marks: (await second.getAnnotations()).filter((a) => a.subtype === 'Highlight').length,
      };
    });
    assert.ok(extraction.angle !== 0 && extraction.empty);
    assert.equal(extraction.marks, 1);
    console.log(
      'PASS AES-256 unlock, ordered unencrypted export, source rotation and original PDF annotations'
    );
    assert.deepEqual(await fs.readFile(pdf), original);
    assert.deepEqual(errors, []);
    console.log('PASS original file is byte-identical; no renderer errors');
  } catch (e) {
    if (win)
      console.error('Window:', (await win.locator('body').innerText({ timeout: 2000 })).slice(-2400));
    throw e;
  } finally {
    await app.close();
    await fs.rm(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 250 });
  }
}
run().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
