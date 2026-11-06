import { expect, test } from '@playwright/test';
import { open } from './open';

test.beforeEach(async ({ page }) => {
	await open(page, '/docs/errors/');
});

test('the sidebar lists every code under its group', async ({ page }) => {
	const nav = page.getByTestId('error-nav');
	await expect(nav.getByRole('link', { name: /^Type \d+$/ })).toBeVisible();
	await expect(nav.locator('.side-code')).toHaveCount(await page.locator('main section[id]').count());
});

test('a search narrows the sidebar and the page, and Enter jumps to the best match', async ({ page }) => {
	const box = page.getByTestId('error-search').first();
	await box.fill('non-exhaustive');
	const nav = page.getByTestId('error-nav');
	await expect(nav.locator('.side-code').first()).toContainText('T0048');
	await expect(page.locator('section#T0048')).toBeVisible();
	await expect(page.locator('section#P0001')).toBeHidden();
	await box.press('Enter');
	await expect(page).toHaveURL(/#T0048$/);
});

test('a code is a search term too', async ({ page }) => {
	await page.getByTestId('error-search').first().fill('w0003');
	await expect(page.getByTestId('error-nav').locator('.side-code').first()).toContainText('W0003');
});

test('slash focuses the search box and Escape clears it', async ({ page }) => {
	await page.keyboard.press('/');
	const box = page.getByTestId('error-search').first();
	await expect(box).toBeFocused();
	await page.keyboard.type('zzzzqqq');
	await expect(page.getByTestId('error-no-results')).toBeVisible();
	await page.keyboard.press('Escape');
	await expect(box).toHaveValue('');
	await expect(page.locator('section#P0001')).toBeVisible();
});
