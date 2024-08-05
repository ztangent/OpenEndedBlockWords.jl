(define (problem block-words)
	(:domain block-words)
	(:objects
		u s o n t g a c h i - block
	)
	(:init
		(handempty)
		(clear s)
		(ontable s)
		(clear u)
		(ontable u)
		(clear a)
		(on a c)
		(on c o)
		(ontable o)
		(clear t)
		(on t h)
		(on h g)
		(on g n)
		(ontable n)
		(clear i)
		(ontable i)	 
	)
	(:goal (and
		;; can 
		(clear c) (ontable n) (on c a) (on a n)
	))
)
