(define (problem block-words)
	(:domain block-words)
	(:objects
		c b j h s a p m u t l - block
	)
	(:init
		(handempty)
		(clear c)
		(on c b)
		(ontable b)
		(clear t)
		(on t l)
		(ontable l)
		(clear s)
		(on s a)
		(on a p)
		(ontable p)
		(clear j)
		(on j h)
		(ontable h)
		(clear m)
		(on m u)
		(ontable u)
	)
	(:goal (and
		;; chump
		(clear c) (ontable p) (on c h) (on h u) (on u m) (on m p) 
	))
)
