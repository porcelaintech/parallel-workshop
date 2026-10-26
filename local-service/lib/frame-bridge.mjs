// 把扩展的 DNR「去 XFO/CSP」能力搬到 CDP：在 workbench 页面启用 Fetch，
// 对文档响应做 header 改写；只需在 iframe 创建前调用一次。
export class FrameBridge {
  constructor({ browserPort, pageURL, log = () => {} }) {
    this.browserPort = browserPort;
    this.pageURL = pageURL;
    this.log = log;
    this.ws = null;
    this.pending = new Map();
    this.nextId = 0;
    this.ready = false;
  }

  async start() {
    if (this.ready && this.ws?.readyState === WebSocket.OPEN) return;
    const targets = await (await fetch(`http://127.0.0.1:${this.browserPort}/json/list`, { signal: AbortSignal.timeout(3000) })).json();
    const target = targets.find(item => item.type === 'page' && item.url.startsWith(this.pageURL));
    if (!target?.webSocketDebuggerUrl) throw new Error('找不到工作台页面，无法初始化 iframe 桥');
    this.ws = new WebSocket(target.webSocketDebuggerUrl);
    const ws = this.ws;
    try {
      await new Promise((resolve, reject) => {
        const finish = error => {
          clearTimeout(timer);
          ws.removeEventListener('open', onOpen);
          ws.removeEventListener('error', onError);
          error ? reject(error) : resolve();
        };
        const onOpen = () => finish();
        const onError = () => finish(new Error('iframe 桥连接失败'));
        const timer = setTimeout(() => finish(new Error('iframe 桥连接超时')), 5000);
        ws.addEventListener('open', onOpen, { once: true });
        ws.addEventListener('error', onError, { once: true });
      });
      ws.addEventListener('message', event => this.onMessage(event));
      const disconnected = () => {
        if (this.ws === ws) { this.ready = false; this.rejectPending(new Error('iframe 桥连接已关闭')); }
      };
      ws.addEventListener('close', disconnected);
      ws.addEventListener('error', disconnected);
      await this.send('Page.enable');
      await this.send('Fetch.enable', { patterns: [{ urlPattern: '*', requestStage: 'Response' }] });
      this.ready = true;
      this.log('iframe 桥已启用（XFO/CSP 响应头改写）');
    } catch (error) {
      await this.stop();
      throw error;
    }
  }

  async stop() {
    this.ready = false;
    if (this.ws?.readyState === WebSocket.OPEN) await this.send('Fetch.disable', {}, 1000).catch(() => {});
    this.rejectPending(new Error('iframe 桥已停止'));
    try { this.ws?.close(); } catch {}
    this.ws = null;
  }

  rejectPending(error) {
    for (const entry of this.pending.values()) { clearTimeout(entry.timer); entry.reject(error); }
    this.pending.clear();
  }

  send(method, params = {}, timeout = 8000) {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return Promise.reject(new Error('iframe 桥未连接'));
    const id = ++this.nextId;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error(`${method}: iframe 桥执行超时`)); }, timeout);
      this.pending.set(id, { resolve, reject, method, timer });
      try { this.ws.send(JSON.stringify({ id, method, params })); }
      catch (error) { clearTimeout(timer); this.pending.delete(id); reject(error); }
    });
  }

  onMessage(event) {
    let message;
    try { message = JSON.parse(event.data); } catch { return; }
    if (message.id) {
      const entry = this.pending.get(message.id);
      if (!entry) return;
      this.pending.delete(message.id);
      clearTimeout(entry.timer);
      if (message.error) entry.reject(new Error(`${entry.method}: ${message.error.message}`));
      else entry.resolve(message.result);
      return;
    }
    if (message.method === 'Fetch.requestPaused') this.onPaused(message.params).catch(error => this.log(`iframe 桥响应处理失败：${error.message}`));
  }

  async onPaused(params) {
    const { requestId, request, responseStatusCode, responseHeaders } = params;
    const headers = responseHeaders || [];
    if (!responseStatusCode || !headers.length) {
      await this.send('Fetch.continueRequest', { requestId }).catch(() => {});
      return;
    }
    const blocked = headers.some(header => ['x-frame-options', 'content-security-policy'].includes(String(header.name).toLowerCase()));
    const filtered = blocked
      ? headers.filter(header => !['x-frame-options', 'content-security-policy'].includes(String(header.name).toLowerCase()))
      : headers;
    if (blocked) {
      try {
        const body = await this.send('Fetch.getResponseBody', { requestId });
        await this.send('Fetch.fulfillRequest', {
          requestId,
          responseCode: responseStatusCode,
          responseHeaders: filtered,
          body: body.base64Encoded ? body.body : Buffer.from(body.body || '', 'utf8').toString('base64')
        });
        this.log(`已放行 iframe 文档：${request?.url || ''}`);
      } catch {
        // 301/302 等无 body 的响应拿不到 body；保留原响应让浏览器自行跟随跳转。
        await this.send('Fetch.continueRequest', { requestId }).catch(() => {});
      }
      return;
    }
    await this.send('Fetch.continueResponse', { requestId, responseCode: responseStatusCode, responseHeaders: filtered })
      .catch(() => this.send('Fetch.continueRequest', { requestId }).catch(() => {}));
  }
}
