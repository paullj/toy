import { errorDocs, renderDoc } from '$lib/errors';

export function load() {
	return { errors: errorDocs().map((d) => ({ code: d.code, title: d.title, html: renderDoc(d) })) };
}
