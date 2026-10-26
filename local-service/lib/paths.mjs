import { homedir, platform } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const SERVICE_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export const REPO_ROOT = resolve(SERVICE_ROOT, '..');

export function defaultDataDir() {
  if (platform() === 'win32') return join(process.env.LOCALAPPDATA || join(homedir(), 'AppData', 'Local'), 'Braintrust');
  if (platform() === 'darwin') return join(homedir(), 'Library', 'Application Support', 'Braintrust');
  return join(process.env.XDG_DATA_HOME || join(homedir(), '.local', 'share'), 'Braintrust');
}

export function defaultConfigDir() {
  if (platform() === 'win32') return join(process.env.APPDATA || join(homedir(), 'AppData', 'Roaming'), 'Braintrust');
  if (platform() === 'darwin') return join(homedir(), 'Library', 'Preferences', 'Braintrust');
  return join(process.env.XDG_CONFIG_HOME || join(homedir(), '.config'), 'Braintrust');
}

export function adaptersDir() {
  const bundled = join(SERVICE_ROOT, 'data', 'adapters');
  return bundled;
}

export function sourceAdaptersDir() {
  return join(REPO_ROOT, 'Sources', 'WorkbenchCore', 'Resources', 'adapters');
}
