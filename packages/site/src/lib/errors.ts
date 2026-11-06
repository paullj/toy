import { Marked } from 'marked';
import { highlightLines } from './toy-syntax';
import type { Options, SearchOptions } from 'minisearch';

// The compiler's own `toy explain` pages, so the site and the CLI never disagree.
const pages = import.meta.glob('../../../compiler/src/diagnostics/errors/*.md', {
	query: '?raw',
	import: 'default',
	eager: true
}) as Record<string, string>;

export type ErrorDoc = { code: string; title: string; markdown: string };

export const GROUPS = [
	{ prefix: 'P', label: 'Parse' },
	{ prefix: 'R', label: 'Resolve' },
	{ prefix: 'T', label: 'Type' },
	{ prefix: 'W', label: 'Warnings' }
];

export function errorDocs(): ErrorDoc[] {
	return Object.entries(pages)
		.map(([path, md]) => {
			const code = path.slice(path.lastIndexOf('/') + 1, -'.md'.length);
			const [heading, ...rest] = md.trim().split('\n');
			return { code, title: heading.replace(/^#\s*[A-Z]\d{4}:\s*/, ''), markdown: rest.join('\n') };
		})
		.sort((a, b) => a.code.localeCompare(b.code));
}

const escape = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

// The pages mark errors with `//` comments, which toy does not have. Swapping each for
// `# ` (same length) lets the toy tokenizer colour the rest of the line as a comment, and
// the token lengths then slice the original text back out.
export function highlightDoc(code: string): string {
	if (/^(\$ |error\[|warning\[)/.test(code.trimStart())) return escape(code);
	const lines = code.split('\n');
	const tokens = highlightLines(lines.map((l) => l.replace(/\/\/(?=(?:[^"]*"[^"]*")*[^"]*$)/, '# ')).join('\n'));
	return lines
		.map((line, i) => {
			let at = 0;
			return (tokens[i] ?? [])
				.map((t) => {
					const text = escape(line.slice(at, (at += t.text.length)));
					return t.cls ? `<span class="${t.cls}">${text}</span>` : text;
				})
				.join('');
		})
		.join('\n');
}

const marked = new Marked({
	renderer: {
		code: ({ text }) => `<pre><code>${highlightDoc(text)}</code></pre>\n`
	}
});

export const renderDoc = (doc: ErrorDoc) => marked.parse(doc.markdown, { async: false });

// Shared by the index build and the client, so both tokenize and weigh fields the same way.
export const SEARCH_OPTIONS: Options = {
	idField: 'code',
	fields: ['code', 'title', 'text'],
	storeFields: ['code', 'title']
};

export const SEARCH_QUERY: SearchOptions = { prefix: true, fuzzy: 0.2, combineWith: 'AND', boost: { code: 4, title: 2 } };

export function plainText(markdown: string): string {
	return markdown.replace(/[`*#>]+/g, ' ').replace(/\s+/g, ' ').trim();
}
