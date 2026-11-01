package main

import "fmt"

type Scale struct{ k int }

func (s Scale) Apply(x int) int { return x * s.k }

func makeAdder(n int) func(int) int { return func(x int) int { return x + n } }

func Map[T, U any](xs []T, f func(T) U) []U {
	out := make([]U, len(xs))
	for i, x := range xs {
		out[i] = f(x)
	}
	return out
}

func Filter[T any](xs []T, keep func(T) bool) []T {
	var out []T
	for _, x := range xs {
		if keep(x) {
			out = append(out, x)
		}
	}
	return out
}

func Fold[T, A any](xs []T, a A, f func(A, T) A) A {
	for _, x := range xs {
		a = f(a, x)
	}
	return a
}

func main() {
	xs := make([]int, 0, 1000)
	for i := 0; i < 1000; i++ {
		xs = append(xs, i)
	}
	scale := Scale{3}
	total := 0
	for round := 0; round < 3000; round++ {
		add := makeAdder(round)
		evens := Filter(Map(Map(xs, add), scale.Apply), func(x int) bool { return x%2 == 0 })
		total += Fold(evens, 0, func(a, x int) int { return a + x })
	}
	fmt.Println(total)
}
