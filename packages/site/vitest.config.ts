import { defineConfig } from 'vitest/config';

export default defineConfig({
	test: { include: ['src/**/*.test.ts'] },
	// The errors page tests read the compiler's `toy explain` pages, as the site build does.
	server: { fs: { allow: ['.', '../compiler/src/diagnostics/errors'] } }
});
