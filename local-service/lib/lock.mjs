import { openSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';

function alive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try { process.kill(pid, 0); return true; } catch (error) { return error?.code === 'EPERM'; }
}

export function acquireLock(path) {
  try {
    const fd = requireOpen(path);
    writeFileSync(fd, `${process.pid}\n`, 'utf8');
    return () => { try { unlinkSync(path); } catch {} };
  } catch (error) {
    if (error.code !== 'EEXIST') throw error;
    let pid = 0;
    try { pid = Number.parseInt(readFileSync(path, 'utf8').trim(), 10); } catch {}
    if (alive(pid)) throw new Error(`智囊服务已经在运行（PID ${pid}）`);
    try { unlinkSync(path); } catch {}
    const fd = requireOpen(path);
    writeFileSync(fd, `${process.pid}\n`, 'utf8');
    return () => { try { unlinkSync(path); } catch {} };
  }
}

function requireOpen(path) {
  return openSync(path, 'wx');
}
