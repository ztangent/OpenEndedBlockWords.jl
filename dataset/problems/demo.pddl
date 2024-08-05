(define (problem block-words)
	(:domain block-words)
	(:objects
		d r a w o e p c - block
	)
	(:init
		(handempty)
		(clear o)
		(ontable o)
		(clear r)
		(on r p)
		(ontable p)
		(clear e)
		(ontable e)
		(clear d)
		(on d a)
		(on a c)
		(ontable c)
		(clear w)
		(ontable w)
	)
	(:goal (and
		;; core
		(clear c) (ontable e) (on c o) (on o r) (on r e)
	))
)
