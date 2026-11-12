import { createServer } from 'node:http';
const frame = `<!doctype html><meta charset="utf-8"><title>Frame OK</title><textarea id="q"></textarea><script>document.title='Frame OK'</script>`;
const blocked = frame;
const parent = `<!doctype html><meta charset="utf-8"><title>Parent</title>
<h1>Parent</h1>
<iframe id="ok" src="http://localhost:48081/frame.html" width="420" height="220"></iframe>
<iframe id="blocked" src="http://localhost:48081/blocked.html" width="420" height="220"></iframe>`;
createServer((req, res) => {
  if (req.url === '/' || req.url === '/parent.html') {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' }); res.end(parent); return;
  }
  if (req.url === '/frame.html') {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' }); res.end(frame); return;
  }
  if (req.url === '/real.html') {
    const real = `<!doctype html><meta charset="utf-8"><title>Real</title><h1>Real</h1><iframe id="real" src="https://www.tongyi.com/qianwen/" width="900" height="600"></iframe>`;
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' }); res.end(real); return;
  }
  if (req.url === '/blocked.html') {
    res.writeHead(200, {
      'content-type': 'text/html; charset=utf-8',
      'x-frame-options': 'DENY',
      'content-security-policy': "frame-ancestors 'none'"
    }); res.end(blocked); return;
  }
  res.writeHead(404); res.end('nope');
}).listen(48081, '127.0.0.1', () => console.log('spike server 48081'));
