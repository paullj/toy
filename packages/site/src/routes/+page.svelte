<script lang="ts">
	import { resolve } from '$app/paths';
	import { useEventListener } from 'runed';
	import CheckOutput from '$lib/components/CheckOutput.svelte';
	import Code from '$lib/components/Code.svelte';
	import ExampleTabs from '$lib/components/ExampleTabs.svelte';
	import Install from '$lib/components/Install.svelte';
	import Performance from '$lib/components/Performance.svelte';
	import ThemeToggle from '$lib/components/ThemeToggle.svelte';
	import icon from '$lib/images/icon.webp';
	import squid from '$lib/images/squid-07-standing.webp';

	const nav = [
		{ id: 'introduction', label: 'Introduction' },
		{ id: 'features', label: 'Features' },
		{ id: 'stdlib', label: 'Standard library' },
		{ id: 'tooling', label: 'Tooling' },
		{ id: 'performance', label: 'Performance' },
		{ id: 'learn', label: 'Learn' }
	];

	const blockColor = ['var(--toy-red)', 'var(--toy-yellow)', 'var(--toy-teal)', 'var(--toy-navy)', 'var(--toy-red)', 'var(--toy-yellow)'];

	const secondary = [
		{ href: resolve('/tour/'), label: 'Tour →' },
		{ href: resolve('/playground/'), label: 'Playground →' },
		{ href: resolve('/docs/'), label: 'Reference →' },
		{ href: resolve('/benchmarks/'), label: 'Benchmarks →' },
		{ href: 'https://github.com/paullj/toy', label: 'Source →' }
	];

	const typeExamples = [
		{
			title: 'Inference',
			blurb: 'Bind a value with <code class="code">:=</code> and its type is inferred. Annotate the boundaries and let the body follow.',
			file: 'order.toy',
			code: `fn main() -> int {
    price := 20                # inferred int
    quantity := 3
    in_stock := quantity > 0   # inferred bool
    if !in_stock {
        return 0
    }
    return price * quantity
}`
		},
		{
			title: 'Generics',
			blurb: 'Generic structs and functions are monomorphized. <code class="code">Pair[int, int]</code> reifies to an ordinary struct — no boxing.',
			file: 'pair.toy',
			code: `struct Pair[A, B] { left: A, right: B }

fn swap[A, B](p: Pair[A, B]) -> Pair[B, A] {
    Pair[B, A] { left: p.right, right: p.left }
}

fn main() -> int {
    point := Pair[int, int] { left: 3, right: 39 }
    return swap(point).left + point.left
}`
		},
		{
			title: 'Protocols',
			blurb: 'A protocol is a set of method signatures. Conform a type with <code class="code">impl Square has Area</code> and call its methods directly.',
			file: 'area.toy',
			code: `protocol Area {
    fn area(self) -> int
}

struct Square { side: int }

impl Square has Area {
    fn area(self) -> int { self.side * self.side }
}`
		},
		{
			title: 'Option',
			blurb: 'There is no null. <code class="code">Option[T]</code> is an ordinary enum, and the postfix <code class="code">?</code> returns early on the empty case.',
			file: 'total.toy',
			code: `pub fn half(n: int) -> Option[int] {
    if n % 2 == 0 { Option.some(n / 2) } else { Option.none }
}

pub fn half_sum(a: int, b: int) -> Option[int] {
    x := half(a)?              # returns none early
    y := half(b)?
    Option.some(x + y)
}`
		},
		{
			title: 'Result',
			blurb: 'Errors are values. <code class="code">Result[T, E]</code> holds a value or an error, and <code class="code">?</code> passes the error up to the caller.',
			file: 'digits.toy',
			code: `pub fn digit(n: int) -> Result[int, str] {
    if n < 0 { return Result.err("negative") }
    if n > 9 { return Result.err("not a digit") }
    Result.ok(n)
}

pub fn pair(a: int, b: int) -> Result[int, str] {
    Result.ok(digit(a)? * 10 + digit(b)?)   # ? returns the error early
}`
		}
	];

	const flowExamples = [
		{
			title: 'If',
			blurb: '<code class="code">if</code> and <code class="code">match</code> are expressions, so they give a value. A function returns its last expression without <code class="code">return</code>.',
			file: 'values.toy',
			code: `fn sign(n: int) -> int {
    if n > 0 { 1 } else if n < 0 { -1 } else { 0 }   # last expression is returned
}

fn main() -> int {
    size := if sign(-5) < 0 { 10 } else { 20 }
    bonus := match size {
        10 -> 1,
        _ -> 2,
    }
    size + bonus
}`
		},
		{
			title: 'Loops',
			blurb: '<code class="code">for</code> walks a range or anything with an iterator. <code class="code">loop</code> is an expression, and a labeled <code class="code">break</code> can leave nested loops with a value.',
			file: 'loops.toy',
			code: `fn main() -> int {
    total := 0
    for i in 1..5 { total += i }        # 1 + 2 + 3 + 4
    # loop is an expression: break hands it a value
    first := @outer loop {
        for j in 0..10 {
            if j * j > total { break @outer j }
        }
    }
    return first
}`
		},
		{
			title: 'Match',
			blurb: 'Enums hold one of several variants. <code class="code">match</code> destructures them, joins arms with <code class="code">|</code>, filters with <code class="code">if</code> guards, and checks that every case is covered.',
			file: 'shapes.toy',
			code: `pub enum Shape { Circle(int), Square(int), Rect(int, int) }

pub fn area(shape: Shape) -> int {
    match shape {
        .Circle(n) | .Square(n) if n < 0 -> 0,   # or-pattern with a guard
        .Circle(r) -> 3 * r * r,
        .Square(side) -> side * side,
        .Rect(w, h) -> w * h,
    }
}`
		},
		{
			title: 'Pipes',
			blurb: '<code class="code">x |> f(a)</code> is <code class="code">f(x, a)</code>: the value on the left becomes the first argument, so a chain of calls reads in the order it runs.',
			file: 'pipeline.toy',
			code: `fn double(x: int) -> int { x * 2 }
fn add(a: int, b: int) -> int { a + b }
fn at_most(x: int, limit: int) -> int {
    if x > limit { limit } else { x }
}

fn main() -> int {
    score := 3
        |> double
        |> add(36)     # add(double(3), 36)
        |> at_most(100)
    return score
}`
		},
		{
			title: 'Closures',
			blurb: 'A lambda captures the variables it names by reference. <code class="code">add(10, _)</code> is short for a lambda, and a <code class="code">mut</code> parameter writes to the caller\'s variable.',
			file: 'closures.toy',
			code: `fn add(a: int, b: int) -> int { a + b }
fn bump(mut n: int) { n += 1 }

fn main() -> int {
    count := 0
    tick := fn(x: int) -> int {
        count += 1             # shared with main, not a copy
        x + count
    }
    add10 := add(10, _)        # fn(x) { add(10, x) }
    bump(count)                # count is now 1
    return tick(add10(5)) + count
}`
		}
	];

	const triangle = `enum Shape { Circle(int), Square(int), Triangle(int, int) }

fn area(shape: Shape) -> int {
    match shape {
        .Circle(r) -> 3 * r * r,
        .Square(side) -> side * side,
    }
}

fn main() -> int {
    area(Shape.Square(4))
}`;

	const stdModules = [
		{ name: 'std/io', what: 'print and read' },
		{ name: 'std/str', what: 'string methods' },
		{ name: 'std/vec', what: 'growable lists' },
		{ name: 'std/map', what: 'hash maps' },
		{ name: 'std/set', what: 'hash sets' },
		{ name: 'std/fs', what: 'files' },
		{ name: 'std/time', what: 'clocks and sleep' },
		{ name: 'std/math', what: 'integer and float math' }
	];

	const callouts = [
		{ href: resolve('/tour/'), kind: 'Tour', label: 'Take the tour →' },
		{ href: resolve('/playground/'), kind: 'Playground', label: 'Try it in the browser →' },
		{ href: resolve('/docs/'), kind: 'Reference', label: 'Read the docs →' },
		{ href: 'https://github.com/paullj/toy', kind: 'Source', label: 'View on GitHub →' }
	];

	// --- Scrollspy ---
	// Active = the last section whose heading has reached the top of the viewport.
	// The line sits just below where a clicked heading lands (its scroll-margin),
	// so short and tall sections are both detected correctly.
	let active = $state(nav[0].id);

	function updateActive() {
		const mark = 80;
		let cur = nav[0].id;
		for (const s of nav) {
			const el = document.getElementById(s.id);
			if (el && el.getBoundingClientRect().top <= mark) cur = s.id;
		}
		active = cur;
	}

	useEventListener(() => window, 'scroll', updateActive, { passive: true });
	useEventListener(() => window, 'resize', updateActive);
	$effect(updateActive);
</script>

<svelte:head>
	<title>toy. a small toy language</title>
	<meta name="description" content="toy is a general purpose language that is statically typed and compiled to native code." />
</svelte:head>

<div class="mx-auto min-h-screen max-w-6xl border-x" style="border-color: var(--border)">
	<div class="grid md:grid-cols-[240px_1fr]">
		<!-- Sidebar -->
		<aside
			class="sticky top-0 hidden h-screen flex-col border-r px-7 pb-8 pt-28 md:flex"
			style="border-color: var(--border)"
		>
			<a href={resolve('/')} class="mb-8 inline-flex items-center gap-2">
				<img src={icon} alt="toy" width="32" height="32" class="h-8 w-8" />
			</a>

			<nav class="flex flex-col gap-1 text-[0.82rem]">
				{#each nav as s}
					<a
						href="#{s.id}"
						class="side-link py-0.5"
						class:active={active === s.id}
					>
						{s.label}
					</a>
				{/each}
			</nav>

			<div class="mt-6 flex flex-col gap-1 border-t pt-5 text-[0.82rem]" style="border-color: var(--border)">
				{#each secondary as l}
					<a href={l.href} class="side-link py-0.5">{l.label}</a>
				{/each}
			</div>

			<!-- Theme -->
			<div class="mt-auto flex items-center gap-2 pt-8 text-[0.82rem]">
				<span class="font-mono text-[0.6rem] uppercase tracking-widest" style="color: var(--fg-muted)">
					Theme
				</span>
				<ThemeToggle class="text-[0.82rem]" />
			</div>
		</aside>

		<!-- Content -->
		<main class="min-w-0 px-6 pb-16 pt-28 sm:px-10 md:px-12 md:pt-[10.5rem]">
			<!-- 01 Introduction -->
			<section id="introduction" class="grid scroll-mt-8 grid-cols-[2.75rem_minmax(0,1fr)] pb-24">
				<div class="flex h-[calc(1.875rem*1.05)] items-center gap-1.5 md:h-[calc(2.25rem*1.05)] font-mono text-[0.7rem]" style="color: var(--fg-muted)">
					<span class="h-2 w-2 rounded-[3px]" style="background: {blockColor[0]}"></span>01
				</div>
				<div>
					<h1 class="flex items-center gap-3 font-sans text-3xl font-bold normal-case leading-[1.05] tracking-tight md:text-4xl">
						<a href="#introduction" class="transition-colors hover:text-[var(--fg-muted)]">
							A small <span class="font-display text-[1.15em] leading-[0] font-normal lowercase tracking-normal" style="color: var(--accent)">toy</span><br />language.
						</a>
						<img
							src={squid}
							alt=""
							width="326"
							height="488"
							class="-mt-[2.1em] h-[4.2em] w-auto shrink-0 translate-y-[0.22em] select-none"
						/>
					</h1>
					<p class="mt-5 max-w-[48ch] text-base leading-snug" style="color: var(--fg-muted)">
						toy is a general purpose language which is statically typed, compiled, and garbage
						collected.
					</p>
					<p class="mt-4 max-w-[48ch] text-base leading-snug" style="color: var(--fg-muted)">
						It aims to be ergonomic and performant but the main goal is for me to learn about language
						design and compiler development.
					</p>
					<Install />
				</div>
			</section>

			<section id="features" class="grid scroll-mt-8 grid-cols-[2.75rem_minmax(0,1fr)] pb-24">
				<div class="flex h-8 items-center gap-1.5 font-mono text-[0.7rem]" style="color: var(--fg-muted)">
					<span class="h-2 w-2 rounded-[3px]" style="background: {blockColor[1]}"></span>02
				</div>
				<div>
					<h2 class="text-2xl">
						<a href="#features" class="transition-colors hover:text-[var(--accent)]">Features</a>
					</h2>
					<p class="mt-3 text-sm leading-snug" style="color: var(--fg-muted)">
						A short look at the language, from its type system to how code branches and loops.
					</p>
					<h3 id="types" class="mt-10 scroll-mt-8 text-lg">Types</h3>
					<p class="mt-1.5 text-sm leading-snug" style="color: var(--fg-muted)">
						toy is statically typed, and most types are inferred.
					</p>
					<ExampleTabs examples={typeExamples} />
					<h3 id="control-flow" class="mt-14 scroll-mt-8 text-lg">Control flow</h3>
					<p class="mt-1.5 text-sm leading-snug" style="color: var(--fg-muted)">
						Branches, loops and ways to pass values and functions around.
					</p>
					<ExampleTabs examples={flowExamples} />
					<p class="mt-8 flex flex-wrap gap-x-5 gap-y-1 text-sm">
						<a href={resolve('/tour/')} class="link">Take the full language tour →</a>
						<a href={resolve('/docs/')} class="link">Read the reference →</a>
					</p>
				</div>
			</section>

			<section id="stdlib" class="grid scroll-mt-8 grid-cols-[2.75rem_minmax(0,1fr)] pb-24">
				<div class="flex h-8 items-center gap-1.5 font-mono text-[0.7rem]" style="color: var(--fg-muted)">
					<span class="h-2 w-2 rounded-[3px]" style="background: {blockColor[2]}"></span>03
				</div>
				<div>
					<h2 class="text-2xl">
						<a href="#stdlib" class="transition-colors hover:text-[var(--accent)]">Standard library</a>
					</h2>
					<p class="mt-3 text-sm leading-snug" style="color: var(--fg-muted)">
						toy ships with a small standard library. Import a module with <code class="code">import std/vec</code>.
					</p>
					<ul class="mt-6 grid grid-cols-2 gap-x-6 gap-y-2.5 sm:grid-cols-4">
						{#each stdModules as m}
							<li class="flex flex-col">
								<code class="font-mono text-[0.8rem] font-semibold">{m.name}</code>
								<span class="text-[0.8rem]" style="color: var(--fg-muted)">{m.what}</span>
							</li>
						{/each}
					</ul>
					<p class="mt-5 text-sm">
						<a href="https://github.com/paullj/toy/blob/main/packages/docs/std.md" class="link">and more →</a>
					</p>
				</div>
			</section>

			<section id="tooling" class="grid scroll-mt-8 grid-cols-[2.75rem_minmax(0,1fr)] pb-24">
				<div class="flex h-8 items-center gap-1.5 font-mono text-[0.7rem]" style="color: var(--fg-muted)">
					<span class="h-2 w-2 rounded-[3px]" style="background: {blockColor[3]}"></span>04
				</div>
				<div>
					<h2 class="text-2xl">
						<a href="#tooling" class="transition-colors hover:text-[var(--accent)]">Tooling</a>
					</h2>
					<p class="mt-3 text-sm leading-snug" style="color: var(--fg-muted)">
						Each error has a code that <code class="code">toy explain</code> documents. Here a <code class="code">Triangle</code> is added to <code class="code">Shape</code> without a match arm. The editor marks the error as you type, and <code class="code">toy check</code> reports the same error:
					</p>
					<div class="mt-2">
						<Code code={triangle} filename="triangle.toy" />
					</div>
					<div class="mt-2">
						<CheckOutput />
					</div>
					<p class="mt-5 text-sm leading-snug" style="color: var(--fg-muted)">
						The compiler also runs as a language server, with hover, completion, go to definition and
						inlay hints. The examples on this page are live editors that use it: hover a name to see its
						type.
					</p>
					<p class="mt-4 flex flex-wrap gap-x-5 gap-y-1 text-sm">
						<a href={resolve('/docs/errors/')} class="link">Every error code →</a>
						<a href={resolve('/playground/')} class="link">Open the playground →</a>
					</p>
				</div>
			</section>

			<section id="performance" class="grid scroll-mt-8 grid-cols-[2.75rem_minmax(0,1fr)] pb-24">
				<div class="flex h-8 items-center gap-1.5 font-mono text-[0.7rem]" style="color: var(--fg-muted)">
					<span class="h-2 w-2 rounded-[3px]" style="background: {blockColor[4]}"></span>05
				</div>
				<div>
					<h2 class="text-2xl">
						<a href="#performance" class="transition-colors hover:text-[var(--accent)]">Performance</a>
					</h2>
					<p class="mt-3 text-sm leading-snug" style="color: var(--fg-muted)">
						toy compiles to native machine code with its own backend, linker and code signer. The compiler is incremental: a rebuild only compiles the functions that changed.
					</p>
					<Performance />
					<p class="mt-5 text-sm">
						<a href={resolve('/benchmarks/')} class="link">See more benchmarks →</a>
					</p>
				</div>
			</section>

			<!-- 06 Learn -->
			<section id="learn" class="grid scroll-mt-8 grid-cols-[2.75rem_minmax(0,1fr)] pb-24">
				<div class="flex h-8 items-center gap-1.5 font-mono text-[0.7rem]" style="color: var(--fg-muted)">
					<span class="h-2 w-2 rounded-[3px]" style="background: {blockColor[5]}"></span>06
				</div>
				<div>
					<h2 class="text-2xl">
						<a href="#learn" class="transition-colors hover:text-[var(--accent)]">Learn</a>
					</h2>
					<p class="mt-3 text-sm leading-snug" style="color: var(--fg-muted)">
						Ready to go deeper? Walk the language tour, browse the reference, or read the source.
					</p>

					<div class="mt-7 grid gap-3 sm:grid-cols-2">
						{#each callouts as c, i}
							<a href={c.href} class="toy-card group flex flex-col gap-2 p-6" style="--block: {blockColor[i]}">
								<span
									class="flex items-center gap-1.5 font-mono text-[0.6rem] uppercase tracking-widest"
									style="color: var(--fg-muted)"
								>
									<span class="h-2 w-2 rounded-[3px]" style="background: var(--block)"></span>
									{c.kind}
								</span>
								<span class="text-sm font-medium tracking-tight transition-colors group-hover:text-[var(--accent)]">
									{c.label}
								</span>
							</a>
						{/each}
					</div>
				</div>
			</section>
			<!-- Trailing whitespace so the last section can scroll up to the mark. -->
			<div aria-hidden="true" class="h-[60vh]"></div>

			<footer
				class="flex items-center justify-between border-t pt-6 font-mono text-[0.7rem]"
				style="border-color: var(--border); color: var(--fg-muted)"
			>
				<span class="inline-flex items-center gap-1.5">
					<img src={icon} alt="" width="16" height="16" class="h-4 w-4" /> toy
				</span>
				<span>a small toy language</span>
			</footer>
		</main>
	</div>
</div>
