package main

import "fmt"

type Tree struct {
	left, right *Tree
}

func build(d int) *Tree {
	if d == 0 {
		return &Tree{}
	}
	return &Tree{build(d - 1), build(d - 1)}
}

func (t *Tree) check() int {
	if t.left == nil {
		return 1
	}
	return 1 + t.left.check() + t.right.check()
}

func main() {
	maxDepth := 13
	total := build(maxDepth + 1).check()
	longLived := build(maxDepth)
	for d := 4; d <= maxDepth; d += 2 {
		iters := 1 << (maxDepth - d + 4)
		for i := 0; i < iters; i++ {
			total += build(d).check()
		}
	}
	fmt.Println(total + longLived.check())
}
