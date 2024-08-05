(define (problem block-words)
	(:domain block-words)
	(:objects
		a c t i o n u f r e s - block
	)
	(:init
		(handempty)
		(clear c)
		(on c i)
		(on i o)
		(on o n)
		(ontable n)
		(clear r)
		(on r s)
		(on s u)
		(ontable u)
		(clear t)
		(on t e)
		(on e a)
		(on a f)
		(ontable f)
	)
	(:goal (and
		;; reaction
		(clear r) (ontable n) (on r e) (on e a) (on a c) (on c t) (on t i) (on i o) (on o n)
	))
)
