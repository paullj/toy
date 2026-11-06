import { readFileSync } from 'node:fs';
import { expect, test } from '@playwright/test';
import { open } from './open';

// The same fixture playwright.config.ts builds the page from.
const records = readFileSync('e2e/fixtures/history.jsonl', 'utf8')
	.trim()
	.split('\n')
	.map((l) => JSON.parse(l));
const names = [...new Set(records.map((r) => r.name as string))];
const shas = [...new Set(records.map((r) => r.sha as string))];

test.beforeEach(async ({ page }) => {
	await open(page, '/benchmarks/');
});

test('every benchmark in the history gets a chart with a line', async ({ page }) => {
	for (const name of names) {
		const chart = page.locator(`figure[data-bench="${name}"]`);
		await expect(chart.locator('figcaption')).toHaveText(name);
		await expect(chart.locator('svg path.lc-path').first()).toBeVisible();
	}
	await expect(page.locator('figure[data-bench]')).toHaveCount(names.length);
	await expect(page.locator('figure[data-trend]')).toHaveCount(2);
	await expect(page.getByTestId('bench-summary').locator('tbody tr')).toHaveCount(names.length);
});

test('the latest commit is selected and links to GitHub', async ({ page }) => {
	const latest = shas.at(-1)!;
	const link = page.getByTestId('bench-selected').locator('a');
	await expect(link).toHaveText(latest.slice(0, 7));
	await expect(link).toHaveAttribute('href', `https://github.com/paullj/toy/commit/${latest}`);
});

test('hovering a point shows its commit, and a click selects it', async ({ page }) => {
	const chart = page.locator('figure[data-bench="loops"]');
	await chart.scrollIntoViewIfNeeded();
	const box = (await chart.locator('svg').first().boundingBox())!;
	// The first commit sits at the left edge of the plot.
	await page.mouse.move(box.x + 70, box.y + box.height / 2);
	const tip = page.locator('.bench-tip');
	await expect(tip).toContainText(shas[0].slice(0, 7));
	await expect(tip).toContainText('Apple M2 Pro');
	await page.mouse.click(box.x + 70, box.y + box.height / 2);
	await expect(page.getByTestId('bench-selected').locator('a')).toHaveText(shas[0].slice(0, 7));
});

test('the metric, x axis and machine controls redraw the charts', async ({ page }) => {
	const wall = page.getByRole('group', { name: 'Metric', exact: true }).getByRole('button', { name: 'Wall time' });
	await wall.click();
	await expect(wall).toHaveAttribute('aria-pressed', 'true');
	await expect(page.getByTestId('bench-summary')).toContainText(' ms');
	await page.getByRole('button', { name: 'By date' }).click();
	await expect(page.locator('figure[data-bench="loops"] svg').first()).toContainText('2026-11-0');
	// The second machine recorded only the last commit.
	await page.getByLabel('Machine').selectOption({ label: 'Apple M1 · 9d2f76d0' });
	await expect(page.getByText('Apple M1 (MacBookAir10,1)')).toBeVisible();
	await expect(page.getByTestId('bench-summary').locator('tbody tr').first()).toContainText('–');
});

test('on a phone, the page never scrolls sideways', async ({ page }) => {
	// Load at phone width, as a phone does: charts measured at desktop width
	// only shrink after a ResizeObserver tick, which a slow runner can miss.
	await page.setViewportSize({ width: 390, height: 800 });
	await page.reload();
	await expect(page.locator('figure[data-bench]').first()).toBeVisible();
	await expect
		.poll(() => page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth))
		.toBe(0);
});
