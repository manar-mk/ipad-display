const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('host', {
  getSources: () => ipcRenderer.invoke('get-sources'),
  selectSource: (id) => ipcRenderer.invoke('select-source', id),
  getInfo: () => ipcRenderer.invoke('get-info'),
  tcpConnect: (host, port) => ipcRenderer.invoke('tcp-connect', host, port),
  tcpDisconnect: () => ipcRenderer.invoke('tcp-disconnect'),
  usbConnect: (port) => ipcRenderer.invoke('usb-connect', port),
  usbList: () => ipcRenderer.invoke('usb-list'),
  openExternal: (url) => ipcRenderer.invoke('open-external', url),
  sendFrame: (arrayBuffer) => ipcRenderer.send('frame', arrayBuffer),
  onStatus: (cb) => ipcRenderer.on('status', (e, s) => cb(s)),
  onServerError: (cb) => ipcRenderer.on('server-error', (e, m) => cb(m)),
});
