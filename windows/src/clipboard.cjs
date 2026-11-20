// Explorer publishes file paths as a CF_HDROP list. Chromium may expose only
// the thumbnail or plain text on paste, so request that list for chat pastes.
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const fs = require('node:fs/promises'),
  path = require('node:path');
const execute = promisify(execFile);
async function copiedFiles() {
  if (process.platform !== 'win32') return [];
  const cmd =
    '[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); Add-Type -AssemblyName System.Windows.Forms; $items=[Windows.Forms.Clipboard]::GetFileDropList(); ConvertTo-Json -Compress -InputObject @($items | ForEach-Object { [string]$_ })';
  const { stdout } = await execute(
    'powershell.exe',
    ['-NoProfile', '-NonInteractive', '-STA', '-Command', cmd],
    { windowsHide: true, timeout: 6000, maxBuffer: 1048576 }
  );
  let total = 0;
  const result = [];
  for (const file of JSON.parse(stdout.trim() || '[]')) {
    const info = await fs.stat(file),
      ext = path.extname(file).toLowerCase();
    if (
      !info.isFile() ||
      !/^\.(pdf|png|jpe?g|gif|bmp|tiff?|webp|avif|txt|md|markdown|csv|json)$/.test(ext)
    )
      throw Error('Unsupported attachment');
    total += info.size;
    if (info.size > 64 * 1024 ** 2 || total > 96 * 1024 ** 2) throw Error('Attachment too large');
    const type =
      ext === '.jpg'
        ? 'image/jpeg'
        : /^\.(png|jpeg|gif|bmp|tiff?|webp|avif)$/.test(ext)
          ? 'image/' + ext.slice(1)
          : '';
    result.push({ name: path.basename(file), type, bytes: await fs.readFile(file) });
  }
  return result;
}
module.exports = { copiedFiles };
