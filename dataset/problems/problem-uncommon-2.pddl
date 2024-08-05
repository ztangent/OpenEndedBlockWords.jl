(define (problem block-words)
	(:domain block-words)
	(:objects
		d a f r t s h i l o - block
	)
	(:init
		(handempty)
		(clear t)
		(on t a)
		(on a d)
		(on d r)
		(ontable r)
		(clear s)
		(ontable s)
		(clear i)
		(on i f)
		(on f o)
		(on o l)
		(on l h)
		(ontable h)		
	)
	(:goal (and
		;; aft
		(clear a) (ontable t) (on a f) (on f t) 
	))
)
