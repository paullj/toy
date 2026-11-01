class Scale {
  constructor(k) {
    this.k = k;
  }
  apply(x) {
    return x * this.k;
  }
}

function makeAdder(n) {
  return (x) => x + n;
}

function main() {
  const xs = [];
  for (let i = 0; i < 1000; i++) xs.push(i);
  const scale = new Scale(3);
  let total = 0;
  for (let round = 0; round < 3000; round++) {
    const add = makeAdder(round);
    total += xs
      .map(add)
      .map(scale.apply.bind(scale))
      .filter((x) => x % 2 === 0)
      .reduce((a, x) => a + x, 0);
  }
  console.log(total);
}

main();
