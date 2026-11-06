import MiniSearch from 'minisearch';
import { errorDocs, plainText, SEARCH_OPTIONS } from '$lib/errors';

export const prerender = true;

export function GET() {
	const index = new MiniSearch(SEARCH_OPTIONS);
	index.addAll(errorDocs().map((d) => ({ code: d.code, title: d.title, text: plainText(d.markdown) })));
	return new Response(JSON.stringify(index), { headers: { 'content-type': 'application/json' } });
}
