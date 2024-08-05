(define (problem block-words)
	(:domain block-words)
	(:objects
		m i s l e k t a f r - block
	)
	(:init
		(handempty)
		(clear f)
		(on f l)
		(ontable l)
		(clear a)
		(on a m)
		(on m t)
		(on t s)
		(ontable s)
		(clear k)
		(on k e)
		(on e i)
		(ontable i)
		(clear r)
		(ontable r)
	)
	(:goal (and
		;; stake
		(clear s) (ontable e) (on s t) (on t a) (on a k) (on k e)
	))
)
