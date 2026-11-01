function fib(n) {
  if (n < 2) return n;
  return fib(n - 1) + fib(n - 2);
}

function collatzSteps(start) {
  let n = start;
  let steps = 0;
  while (n !== 1) {
    n = n % 2 === 0 ? n / 2 : 3 * n + 1;
    steps++;
  }
  return steps;
}

function main() {
  let total = fib(32);
  for (let i = 1; i < 500000; i++) total += collatzSteps(i);
  console.log(total);
}

main();
