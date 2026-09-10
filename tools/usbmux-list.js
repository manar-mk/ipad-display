// Checks the USB layer: asks usbmuxd for attached devices, then tries to open port 7801 on the first one.
const usbmux = require('../usbmux');
(async () => {
  try {
    const devs = await usbmux.listDevices();
    console.log('usbmuxd OK, USB devices:', devs.length ? devs : 'none');
    if (!devs.length) process.exit(1);
    const port = parseInt(process.argv[2] || '7801', 10);
    try { const s = await usbmux.connect(port, devs[0].id); console.log('tunnel to device port', port, 'OPEN — iPad Display app is running'); s.destroy(); }
    catch (e) { console.log('tunnel to device port', port, 'failed:', e.message); }
  } catch (e) { console.error(e.message); process.exit(2); }
})();
