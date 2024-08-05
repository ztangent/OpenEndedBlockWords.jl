(define (problem block-words)
	(:domain block-words)
	(:objects
		a i s e f l n b m - block
	)
	(:init
		(handempty)
		(clear m)
		(on m a)
		(on a i)
		(ontable i)
		(clear f)
		(on f s)
		(ontable s)
		(clear e)
		(ontable e)
		(clear l)
		(on l b)
		(on b n)
		(ontable n)
	)
	(:goal (and
		;; flame
		(clear f) (ontable e) (on f l) (on l a) (on a m) (on m e)
	))
)
