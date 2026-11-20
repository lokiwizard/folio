const { contextBridge, ipcRenderer, webUtils } = require('electron');
const commands = [
  'init',
  'copiedFiles',
  'forgetRecent',
  'open',
  'read',
  'recent',
  'paper',
  'savePaper',
  'settings',
  'profile',
  'removeProfile',
  'models',
  'test',
  'chat',
  'stop',
  'copyImage',
  'extract',
  'exportNotes',
  'fullscreen',
  'external',
  'print',
  'ready',
  'closed',
];
const api = Object.fromEntries(
  commands.map((name) => [name, (...args) => ipcRenderer.invoke('folio:' + name, ...args)])
);
api.dropPDF = (file) => ipcRenderer.invoke('folio:drop', webUtils.getPathForFile(file));
api.on = (event, callback) => {
  if (!['open', 'closing', 'delta', 'menu'].includes(event)) throw Error('Unknown event');
  ipcRenderer.on('folio:' + event, (_event, data) => callback(data));
};
contextBridge.exposeInMainWorld('folio', api);
