import { readFileSync } from 'node:fs';
import { expect, test, type Page } from '@playwright/test';

// The same fixture playwright.config.ts builds the page from.
const run = JSON.parse(readFileSync('e2e/fixtures/peers.json', 'utf8'));
const names = [...new Set(run.results.map((r: { name: string }) => r.name))] as string[];
type Result = { name: string; lang: string; source: string };
const results = (name: string) => run.results.filter((r: Result) => r.name === name) as Result[];
const langs = (name: string) => results(name).map((r) => r.lang);

// A tooltip of a chart the mouse crossed while scrolling can still be fading out.
async function expectOneTip(page: Page) {
	await expect(page.locator('.peer-tip')).toHaveCount(1);
}

test.beforeEach(async ({ page }) => {
	await page.goto('/benchmarks/');
});

test('the peer view sits under the history with its caveat and run details', async ({ page }) => {
	const peers = page.getByTestId('peers');
	await expect(peers.getByRole('note')).toContainText('pinch of salt');
	const meta = page.getByTestId('peers-meta');
	await expect(meta).toContainText('Apple M2 Pro');
	await expect(meta).toContainText(run.date.slice(0, 10));
	await expect(meta).toContainText(run.toolchains.go.version);
	const below = await page.evaluate(() => {
		const last = [...document.querySelectorAll('figure[data-bench]')].at(-1)!;
		return !!(last.compareDocumentPosition(document.querySelector('[data-testid="peers"]')!) & Node.DOCUMENT_POSITION_FOLLOWING);
	});
	expect(below).toBe(true);
});

test('toy bars come from the newest main record on the peers machine, others from the peer run', async ({ page }) => {
	const toy = page.getByTestId('peers-toy');
	const newest = 'bcbe70013688a3c739bec83ef757c70871fe5032';
	await expect(toy.getByRole('link', { name: newest.slice(0, 7) })).toHaveAttribute('href', `https://github.com/paullj/toy-compiler/commit/${newest}`);
	await expect(toy).toContainText('2026-11-03');
	// The history fixture has no binary_trees, so that bar falls back to the peer run's toy row.
	await expect(toy).toContainText('binary_trees');
	await expect(toy.getByRole('link', { name: run.toy_commit.slice(0, 7) })).toHaveAttribute('href', `https://github.com/paullj/toy-compiler/commit/${run.toy_commit}`);
	const chart = page.locator('figure[data-peer="loops"]');
	await chart.scrollIntoViewIfNeeded();
	const box = (await chart.locator('svg .lc-bar').first().boundingBox())!;
	await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
	await expectOneTip(page);
	await expect(page.locator('.peer-tip')).toContainText('595.0 ms');
});

test('every benchmark gets one bar chart with a bar per language and source links', async ({ page }) => {
	await expect(page.locator('figure[data-peer]')).toHaveCount(names.length);
	for (const name of names) {
		const chart = page.locator(`figure[data-peer="${name}"]`);
		await expect(chart.locator('figcaption')).toHaveText(name);
		await expect(chart.locator('svg .lc-bar')).toHaveCount(langs(name).length);
		for (const r of results(name)) {
			await expect(chart.locator('.sources a', { hasText: r.lang })).toHaveAttribute('href', `https://github.com/paullj/toy-compiler/blob/main/${r.source}`);
		}
	}
});

test('wall time is the default; peak memory and the log scale redraw the charts', async ({ page }) => {
	const chart = page.locator('figure[data-peer="loops"]');
	await expect(page.getByRole('group', { name: 'Peer metric' }).getByRole('button', { name: 'Wall time' })).toHaveAttribute('aria-pressed', 'true');
	await expect(chart.locator('svg').first()).toContainText(' ms');
	await page.getByRole('group', { name: 'Peer metric' }).getByRole('button', { name: 'Peak memory' }).click();
	await expect(chart.locator('svg').first()).toContainText('MiB');
	const linear = await chart.locator('svg .lc-bar').first().getAttribute('d');
	await page.getByRole('button', { name: 'Log' }).click();
	await expect(page.getByRole('button', { name: 'Log' })).toHaveAttribute('aria-pressed', 'true');
	await expect.poll(() => chart.locator('svg .lc-bar').first().getAttribute('d')).not.toBe(linear);
	await expect(chart.locator('svg .lc-bar')).toHaveCount(langs('loops').length);
});

test('hovering a bar names its toolchain', async ({ page }) => {
	const chart = page.locator('figure[data-peer="loops"]');
	await chart.scrollIntoViewIfNeeded();
	// The tooltip's hit area covers the bars, so hover by position rather than on the bar node.
	const box = (await chart.locator('svg .lc-bar').nth(1).boundingBox())!;
	await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
	await expectOneTip(page);
	await expect(page.locator('.peer-tip')).toContainText(run.toolchains.c.version);
});

test('in the memory view, a peer that uses less reads as less memory, not faster', async ({ page }) => {
	await page.getByRole('group', { name: 'Peer metric' }).getByRole('button', { name: 'Peak memory' }).click();
	const chart = page.locator('figure[data-peer="alloc"]');
	await chart.scrollIntoViewIfNeeded();
	const box = (await chart.locator('svg .lc-bar').nth(1).boundingBox())!;
	await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
	await expectOneTip(page);
	await expect(page.locator('.peer-tip')).toContainText('less memory than toy');
	await expect(page.locator('.peer-tip')).not.toContainText('faster');
});

test('on a phone, the peer view never scrolls sideways', async ({ page }) => {
	// Load at phone width, as a phone does: charts measured at desktop width
	// only shrink after a ResizeObserver tick, which a slow runner can miss.
	await page.setViewportSize({ width: 390, height: 800 });
	await page.reload();
	await expect(page.locator('figure[data-peer]').first()).toBeAttached();
	await expect
		.poll(() => page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth))
		.toBe(0);
});
