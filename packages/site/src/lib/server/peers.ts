import { existsSync, readFileSync } from 'node:fs';
import { parsePeers, type PeerRun } from '../bench';

export function readPeers(path: string): PeerRun | null {
	return existsSync(path) ? parsePeers(readFileSync(path, 'utf8')) : null;
}
