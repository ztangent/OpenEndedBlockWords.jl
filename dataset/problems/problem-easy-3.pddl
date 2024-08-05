(define (problem block-words)
	(:domain block-words)
	(:objects
		k b h n s e w o t - block
	)
	(:init
		(handempty)
		(clear s)
		(on s o)
		(on o h)
		(ontable h)
		(clear k)
		(on k n)
		(ontable n)
		(clear w)
		(on w e)
		(ontable e)
		(clear b)
		(on b t)
		(ontable t)
	)
	(:goal (and
		;; know
		(clear k) (ontable w) (on k n) (on n o) (on o w)
	))
)
