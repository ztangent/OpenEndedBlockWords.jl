(define (problem block-words)
	(:domain block-words)
	(:objects
		r d v i s f h n g a b - block
	)
	(:init
		(handempty)
		(clear r)
		(on r d)
		(on d v)
		(ontable v)
		(clear i)
		(on i s)
		(on s f)
		(ontable f)
		(clear h)
		(ontable h)
		(clear n)
		(on n g)
		(on g a)
		(on a b)
		(ontable b)
	)
	(:goal (and
		;; banish
		(clear b) (ontable h) (on b a) (on a n) (on n i) (on i s) (on s h)
	))
)
