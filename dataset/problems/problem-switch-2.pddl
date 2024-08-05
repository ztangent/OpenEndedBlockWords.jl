(define (problem block-words)
	(:domain block-words)
	(:objects
		p e i n o g h t r s - block
	)
	(:init
		(handempty)
		(clear p)
		(on p e)
		(ontable e)
		(clear g)
		(on g n)
		(on n t)
		(on t h)
		(ontable h)
		(clear i)
		(on i o)
		(ontable o)
		(clear r)
		(ontable r)
		(clear s)
		(ontable s)
	)
	(:goal (and
		;; short
		(clear s) (ontable t) (on s h) (on h o) (on o r) (on r t)
	))
)
