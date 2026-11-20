import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';

/** Walks up from this file to the directory holding pnpm-workspace.yaml. */
export function findWorkspaceRoot(start: string = __dirname): string {
  let dir = start;
  for (;;) {
    if (existsSync(join(dir, 'pnpm-workspace.yaml'))) {
      return dir;
    }
    const parent = dirname(dir);
    if (parent === dir) {
      throw new Error(`pnpm-workspace.yaml not found above ${start}`);
    }
    dir = parent;
  }
}
