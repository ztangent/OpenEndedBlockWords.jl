(define (problem block-words)
	(:domain block-words)
	(:objects
		l u t v i a w r o e - block
	)
	(:init
		(handempty)
		(clear l)
		(ontable l)
		(clear u)
		(on u t)
		(on t v)
		(on v i)
		(ontable i)
		(clear w)
		(ontable w)
		(clear a)
		(ontable a)
		(ontable a)
		(clear r)
		(ontable r)
		(clear o)
		(on o e)
		(ontable e)
	)
	(:goal (and
		;; liter
		(clear l) (ontable r) (on l i) (on i t) (on t e) (on e r)  
	))
)