(define (problem block-words)
	(:domain block-words)
	(:objects
		n r o e i u c h g t s - block
	)
	(:init
		(handempty)
		(clear g)
		(on g s)
		(on s o)
		(on o e)
		(ontable e)
		(clear h)
		(on h n)
		(on n i)
		(ontable i)
		(clear t)
		(on t r)
		(on r u)
		(ontable u)
		(clear c)
		(ontable c)
	)
	(:goal (and
		;; rough
		(clear r) (ontable h) (on r o) (on o u) (on u g) (on g h)
	))
)
