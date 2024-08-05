(define (problem block-words)
	(:domain block-words)
	(:objects
		e r h m o t c u s a - block
	)
	(:init
		(handempty)
		(clear m)
		(on m o)
		(on o e)
		(on e r)
		(ontable r)
		(clear t)
		(on t h)
		(ontable h)
		(clear a)
		(on a c)
		(ontable c)		
		(clear u)
		(ontable u)
		(clear s)
		(ontable s)
	)
	(:goal (and
		;; mother
		(clear m) (ontable r) (on m o) (on o t) (on t h) (on h e) (on e r)
	))
)
