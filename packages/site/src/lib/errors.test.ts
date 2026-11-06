import { expect, it } from 'vitest';
import { errorDocs, highlightDoc } from './errors';

it('colours a // comment as a comment and keeps its text', () => {
	const html = highlightDoc('x := 1   // error: bad');
	expect(html).toContain('<span class="tok-com">// error: bad</span>');
	expect(html.replace(/<[^>]+>/g, '')).toBe('x := 1   // error: bad');
});

it('leaves a // inside a string alone', () => {
	expect(highlightDoc('s := "a//b"')).not.toContain('tok-com');
});

it('leaves compiler output plain', () => {
	expect(highlightDoc('error[T0048]: nope')).toBe('error[T0048]: nope');
});

it('keeps the text of every code block in every page', () => {
	const unescape = (s: string) => s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');
	for (const doc of errorDocs())
		for (const [, code] of doc.markdown.matchAll(/```\n([\s\S]*?)```/g))
			expect(unescape(highlightDoc(code.replace(/\n$/, '')).replace(/<[^>]+>/g, ''))).toBe(code.replace(/\n$/, ''));
});
