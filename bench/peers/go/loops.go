package main

import "fmt"

func fib(n int) int {
	if n < 2 {
		return n
	}
	return fib(n-1) + fib(n-2)
}

func collatzSteps(start int) int {
	n, steps := start, 0
	for n != 1 {
		if n%2 == 0 {
			n = n / 2
		} else {
			n = 3*n + 1
		}
		steps++
	}
	return steps
}

func main() {
	total := fib(32)
	for i := 1; i < 500000; i++ {
		total += collatzSteps(i)
	}
	fmt.Println(total)
}
