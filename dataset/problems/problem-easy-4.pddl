(define (problem block-words)
	(:domain block-words)
	(:objects
		d t a i n s b r p - block
	)
	(:init
		(handempty)
		(clear d)
		(on d t)
		(ontable t)
		(clear s)
		(on s n)
		(on n a)
		(ontable a)
		(clear b)
		(on b p)
		(on p i)
		(on i r)
		(ontable r)
	)
	(:goal (and
		;; drains
		(clear d) (ontable s) (on d r) (on r a) (on a i) (on i n) (on n s)
	))
)
