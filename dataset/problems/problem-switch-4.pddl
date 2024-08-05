(define (problem block-words)
	(:domain block-words)
	(:objects
		a o h l e c t g n s - block
	)
	(:init
		(handempty)
		(clear h)
		(on h s)
		(on s o)
		(on o a)
		(on a l)
		(ontable l)
		(clear n)
		(on n e)
		(ontable e)
		(clear g)
		(on g c)
		(on c t)
		(ontable t)
	)
	(:goal (and
		;; clone
		(clear c) (ontable e) (on c l) (on l o) (on o n) (on n e)
	))
)
