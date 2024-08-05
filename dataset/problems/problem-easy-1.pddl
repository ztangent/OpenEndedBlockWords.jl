(define (problem block-words)
	(:domain block-words)
	(:objects
		l a y e s t f b m - block
	)
	(:init
		(handempty)
		(clear b)
		(ontable b)
		(clear e)
		(ontable e)
		(clear s)
		(on s t)
		(on t f)
		(ontable f)
		(clear l)
		(ontable l)
		(clear m)
		(ontable m)
		(clear a)
		(on a y)
		(ontable y)
	)
	(:goal (and
		;; yeast
		(clear y) (ontable t) (on y e) (on e a) (on a s) (on s t)
	))
)
