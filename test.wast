(module
	(func $print_i32 (import "spectest" "print_i32") (param i32))
	(memory $memory (export "memory") 1)
	(memory $output (export "output") 1 1)
	(global $output_length (export "output_length") (mut i32) (i32.const 0))

	(func $write (export "write") (param $base i32) (param $len i32)
		(local $old_length i32)
		(local $new_length i32)
		;;(local $new_pages i32)

		(local.tee $old_length (global.get $output_length))
		(local.tee $new_length (i32.add (local.get $len)))

		drop
		;;(local.tee $new_pages (i32.sub (i32.shr_u (i32.add (i32.const 65535)) (i32.const 16)) (memory.size $output)))
		;;(if (then (drop (memory.grow $output (local.get $new_pages)))))

		(memory.copy $output $memory (local.get $old_length) (local.get $base) (local.get $len))
		(global.set $output_length (local.get $new_length))
	)

	(func $trace_i32 (export "trace_i32") (param $v i32) (result i32)
		(call $print_i32 (local.get $v))
		local.get $v
	)
)
(register "")

;; The spec interpreter allows referring to external files but Wasmtime doesn't
;;(input "jot.wat")
(module
	(func $write (import "" "write") (param i32 i32))
	(memory (import "" "memory") 1)

	(global $strtab (mut i32) (i32.const 0))
	(global $offsets_base (mut i32) (i32.const 0))
	(global $stack_base (mut i32) (i32.const 0))
	(global $stack_top (mut i32) (i32.const 0))

	(memory $closures 1)

	(global $next_free_closure (mut i32) (i32.const 0))

	(func $ensure_memory (param $bytes i32)
		(local $pages i32)
		;; convert to 64kB pages, rounded up
		(i32.shr_u (i32.add (local.get $bytes) (i32.const 0xFFFF)) (i32.const 16))
		;; determine how many more pages we need than we have already
		(local.tee $pages (i32.sub (memory.size)))
		;; check if we need more pages than are already allocated
		(if (i32.gt_s (i32.const 0)) (then
			;; ignore errors from grow; just let the following access trap
			(drop (memory.grow (local.get $pages)))
		))
	)

	;; Given that the input program has already been written into the first $length
	;; bytes of memory, validate that it fits our required syntax and precompute all
	;; the branch target locations.
	(func $load (export "load") (param $length i32)
		(local $base i32)
		(local $stack i32)
		(local $pending i32)
		(local $i i32)
		(local $j i32)

		;; TODO: trim trailing P combinators from the end

		(if (i32.eqz (local.get $length)) (then
			unreachable
		))

		(global.set $strtab (local.get $length))

		;; two data structures in this function need four bytes per input instruction
		(local.set $i (i32.shl (local.get $length) (i32.const 2)))

		;; stash our string table after the input program
		(memory.init $strtab (local.get $length) (i32.const 0) (local.tee $j (global.get $strtab_length)))
		(i32.add (local.get $length) (local.get $j))
		;; pad the length up to four byte alignment, just to be nice
		(local.tee $base (i32.and (i32.add (i32.const 3)) (i32.const -4)))
		;; reserve space for an additional four bytes per input instruction
		(local.tee $pending (local.tee $stack (i32.add (local.get $i))))
		;; reserve that many four byte elements again for the initial stack
		(i32.add (local.get $i))
		call $ensure_memory

		(global.set $offsets_base (local.get $base))
		(global.set $stack_base (local.get $stack))

		(local.tee $i (i32.sub (local.get $length) (i32.const 1)))
		;; convert the last instruction but exclude it from the following loop
		;; because it does not have any further instructions after it for a P
		;; instruction to refer to
		(drop (call $convert_bytecode))

		(loop $convert
			(if (local.get $i) (then
				(local.tee $j (i32.sub (local.get $i) (i32.const 1)))
				(if (call $convert_bytecode) (then
					;; one of IKS, so push the offset after this on the stack
					(i32.store (local.get $pending) (local.get $i))
					(local.set $pending (i32.add (local.get $pending) (i32.const 4)))
				) (else
					;; this is P, so pop an offset off the stack and associate it with this instruction
					(if (i32.eq (local.get $stack) (local.get $pending)) (then unreachable))
					(i32.store
						;; address is $base+4*$j
						(i32.add (local.get $base) (i32.shl (local.get $j) (i32.const 2)))
						;; value comes from top of stack
						(i32.load (local.tee $pending (i32.sub (local.get $pending) (i32.const 4))))
					)
				))
				(local.set $i (local.get $j))
				br $convert
			))
		)

		(global.set $stack_top (local.get $pending))

		(global.set $next_free_closure (i32.const 4))
		(i32.store $closures (i32.const 8) (i32.const 0))
	)

	;; convert ASCII input "PIKS" to contiguous small integers 0-3 which are more convenient for the interpreter.
	;; this function both overwrites the input program with the bytecode version and also returns the bytecode.
	(func $convert_bytecode (param $offset i32) (result i32)
		(local $v i32)
		;; get the byte of the program, which is expected to be one of PIKS
		(i32.load8_u (local.get $offset))
		;; save a copy of this byte on the stack to check against later
		local.tee $v

		;; lookup table that's inverse of the transformation we're doing now
		i32.const 0x50_49_4B_53 ;; ASCII bytes for PIKS

		;; this is excessively clever and therefore a terrible idea, but I had fun.
		;; when subtracting 'I' from each of PIKS, the result is: 0b111, 0b0, 0b10, 0b1010
		;; the number of bits set in each of those is 3, 0, 1, 2, which is
		;; almost what we want, except they're all off by one. if we add one bit
		;; that isn't set in any of those cases, such as 0b10000, then the
		;; popcount becomes 4, 1, 2, 3; mask that with 0b11 to get the final
		;; answer.
		(i32.sub (local.get $v) (i32.const 0x39)) ;; ASCII code for 'I' (0x49), minus 16 (0x10)
		i32.popcnt
		(i32.and (i32.const 3))
		local.tee $v

		;; that computation will produce a number between 0-3 for any input byte,
		;; but we only want to accept four specific letters. so look up this
		;; result in the above inverse lookup table.
		(i32.shl (i32.const 3))
		i32.shl
		(i32.shr_u (i32.const 24))

		;; if the inverse is not equal to the original input, then the input was garbage
		(if (i32.ne) (then unreachable))

		;; good input, write it back over the input and return it
		(i32.store8 (local.get $offset) (local.get $v))
		local.get $v
	)

	(func $eval (export "eval") (param $fuel i32)
		(local $pc i32)
		(local $inst i32)
		(local $tmp i32)
		(local $local_base i32)
		(local $stack_top i32)
		(local.set $local_base (global.get $stack_base))
		(local.set $stack_top (global.get $stack_top))
		(loop $one
			(if (i32.eqz (local.get $fuel)) (then return))
			(local.set $fuel (i32.sub (local.get $fuel) (i32.const 1)))

			(local.tee $inst (i32.load8_u (local.get $pc)))
			(if (then
				;; for I/K/S, the bytecode value (1-3) is the number of operands to
				;; pop off the stack.
				(local.tee $tmp (i32.shr_u (i32.sub (local.get $stack_top) (local.get $local_base)) (i32.const 2)))
				(if (i32.lt_u (local.get $inst)) (then
					;; stack underflow means the current instruction is irreducible.
					(call $irreducible (local.get $inst) (local.get $tmp))
					;; if there's nothing more on the full stack, we've reduced everything as
					;; far as possible and can stop now.
					(if (i32.eq (local.get $stack_top) (global.get $stack_base)) (then return))
					;; if the stack is non-empty, pop the next thing off the stack,
					;; and jump to it to see if there's anything there we can reduce.
					;; but when evaluating the next part, pretend the current contents of
					;; the stack don't exist by setting local_base to exclude them for
					;; the irreducibility check.
					(i32.sub (local.get $stack_top) (i32.const 4))
					local.tee $stack_top
					local.tee $local_base
					(local.set $pc (i32.load))
				) (else
					;; all three of I/K/S jump next to the offset on top of the stack.
					(local.set $pc (i32.load (i32.sub (local.get $stack_top) (i32.const 4))))
					(local.set $stack_top (i32.sub (local.get $stack_top) (i32.shl (local.get $inst) (i32.const 2))))

					(if (i32.eq (local.get $inst) (i32.const 2)) (then
						(call $unref_closure (i32.load (local.get $stack_top)))
					))

					(if (i32.eq (local.get $inst) (i32.const 3)) (then
						;; S does some extra things with its stack arguments.
						;; note that these pushes can't overrun the stack because we just
						;; popped three things and are only pushing two.
						(i32.store
							(local.get $stack_top)
							(call $build_closure
								(i32.load offset=4 (local.get $stack_top))
								(local.tee $tmp (i32.load (local.get $stack_top)))
							)
						)
						(call $ref_closure (local.get $tmp))
						(i32.store offset=4 (local.get $stack_top) (local.get $tmp))
						(local.set $stack_top (i32.add (local.get $stack_top) (i32.const 8)))
					))
				))

				(loop $resolve_closure
					(if (i32.lt_s (local.get $pc) (i32.const 0)) (then
						(call $eval_closure (local.get $pc))
						local.set $tmp
						local.set $pc

						;; set up operands to store using old value of stack pointer
						local.get $stack_top
						local.get $tmp
						;; before actually storing there, update the stack pointer and grow memory
						(call $ensure_memory (local.tee $stack_top (i32.add (local.get $stack_top) (i32.const 4))))
						i32.store

						br $resolve_closure
					))
				)
			) (else
				;; push the offset associated with this P instruction onto the stack.
				;; we may be out of memory; try to grow it if necessary.
				local.get $stack_top
				(i32.load (i32.add (global.get $offsets_base) (i32.shl (local.get $pc) (i32.const 2))))
				(call $ensure_memory (local.tee $stack_top (i32.add (local.get $stack_top) (i32.const 4))))
				i32.store

				;; continue on to the next instruction.
				(local.set $pc (i32.add (local.get $pc) (i32.const 1)))
			))
			br $one
		)
	)

	(data $strtab "IPKPPS")
	(global $strtab_length i32 (i32.const 6))

	(func $irreducible (param $inst i32) (param $avail i32)
		(local.set $avail (i32.add (local.get $avail) (i32.const 1)))

		;; the starting offset in the string table is (n*(n-1)/2): 0, 1, or 3
		(i32.shr_u (i32.mul (local.get $inst) (i32.sub (local.get $inst) (i32.const 1))) (i32.const 1))
		;; skip some leading Ps so that only the number of elements that were
		;; available on the stack have a P in the output. the string table above
		;; has $inst-1 Ps in each group (because the max we could need is less
		;; than $inst), so $inst-($avail+1) (but the +1 is above)
		(i32.add (i32.sub (local.get $inst) (local.get $avail)))
		(i32.add (global.get $strtab))

		;; length to write is ($avail+1)
		local.get $avail

		call $write
	)

	(func $build_closure (param $x i32) (param $y i32) (result i32)
		(local $c i32)
		(local $t i32)

		(local.tee $c (global.get $next_free_closure))
		(local.tee $t (i32.load $closures offset=4))
		(if (result i32) (then
			;; the free list was not empty, just pop its next entry
			local.get $t
		) (else
			;; this was the last entry in the free list, which is always at the
			;; highest address we've used so far. we need to put a new closure
			;; on the free list at the next higher address now, and tag it as
			;; the new end of the list.
			;; TODO grow memory if necessary
			(i32.store $closures offset=16 (local.get $c) (i32.const 0))
			(i32.add (local.get $c) (i32.const 12))
		))
		global.set $next_free_closure

		(i32.store $closures offset=8 (local.get $c) (local.get $y))
		(i32.store $closures offset=4 (local.get $c) (local.get $x))
		(i32.store $closures (local.get $c) (i32.const 1))
		;; set the high bit to mark that this is a closure, not a pointer to input bytecode
		(i32.xor (local.get $c) (i32.const -1))
	)

	(func $eval_closure (param $c i32) (result i32 i32)
		(local $t i32)
		;; clear the high bit to get the actual address in the closures address space
		(local.tee $t (i32.xor (local.get $c) (i32.const -1)))
		i32.load $closures offset=4
		local.get $t
		i32.load $closures offset=8

		local.get $c
		call $unref_closure
	)

	(func $ref_closure (param $c i32)
		(if (i32.lt_s (local.get $c) (i32.const 0)) (then
			;; get the real address for this closure
			(local.tee $c (i32.xor (local.get $c) (i32.const -1)))

			;; increment this closure's reference count
			(i32.store $closures
				(i32.add
					(i32.load $closures (local.get $c))
					(i32.const 1)
				)
			)
		))
	)

	(func $unref_closure (param $c i32)
		(local $t i32)
		(local $head i32)
		loop $loop
		(if (i32.lt_s (local.get $c) (i32.const 0)) (then
			;; get the real address for this closure
			(local.tee $c (i32.xor (local.get $c) (i32.const -1)))

			;; decrement this closure's reference count and save the new count in $t
			(i32.store $closures
				(local.tee $t (i32.sub
					(i32.load $closures (local.get $c))
					(i32.const 1)
				))
			)

			(if (i32.eqz (local.get $t)) (then
				;; get the x pointer as the next closure we'll visit
				(i32.load $closures offset=4 (local.get $c))

				;; overwrite the x pointer with an intrinsic list of closures whose y
				;; pointers we still need to free
				(i32.store $closures offset=4 (local.get $c) (local.get $head))
				(local.set $head (local.get $c))

				;; continue the loop at the x pointer
				local.set $c
				br $loop
			))
		))

		(if (local.get $head) (then
			;; get the y pointer as the next closure we'll visit
			(local.set $c (i32.load $closures offset=8 (local.get $head)))

			;; get the x pointer as the next $head
			(i32.load $closures offset=4 (local.get $head))

			;; add the closure at $head to the free list
			(i32.store $closures offset=4 (local.get $head) (global.get $next_free_closure))
			(global.set $next_free_closure (local.get $head))

			;; finish popping this closure off $head
			local.set $head
			br $loop
		))
		end $loop
	)
)

(register "interpreter")

(module
	(func $print_i32 (import "spectest" "print_i32") (param i32))
	(func $trace_i32 (import "" "trace_i32") (param i32) (result i32))

	(func $load (import "interpreter" "load") (param i32))
	(func $eval (import "interpreter" "eval") (param i32))
	(memory $input (import "" "memory") 1)
	(memory $output (import "" "output") 0)
	(global $output_length (import "" "output_length") (mut i32))

	(memory $tests 1)

	(data (memory $tests) (i32.const 0)
		"PII\00" "I\00"
		"PIK\00" "K\00"
		"PPKII\00" "I\00"
		"PPKKI\00" "K\00"
		"KII\00" "I\00"
		"KKI\00" "K\00"
		"PKI\00" "PKI\00"
		"KI\00" "PKI\00"
		"PKK\00" "PKK\00"
		"KK\00" "PKK\00"
		"PPSSI\00" "PPSSI\00"
		"SSI\00" "PPSSI\00"
		"SPSI\00" "PSPSI\00"
		"PPKIPKI\00" "I\00"
		"PPPSKKI\00" "I\00"
		"PPIKPIK\00" "PKK\00"
		"PPPSIIK\00" "PKK\00"
		"PPIIPII\00" "I\00"
		"PPPSIII\00" "I\00"
		"PPPPPSPKSKSSS\00" "PSPSS\00"
		"PPPSPKSSS\00" "PSPSS\00"
		"PPPSSPKKI\00" "PPSIK\00"
	)

	(func $test (export "test")
		(local $i i32)
		(local $start i32)
		(local $len i32)
		(loop $l
			;; copy input
			(local.tee $len (call $strlen (local.get $start)))

			;;(call $print_i32 (local.get $start))
			;;(call $print_i32 (local.get $len))

			(if (i32.eqz) (then return))
			(call $print_i32 (local.tee $i (i32.add (local.get $i) (i32.const 1))))

			(memory.copy $input $tests (i32.const 0) (local.get $start) (local.get $len))

			;; run test
			(global.set $output_length (i32.const 0))
			(call $load (local.get $len))
			(call $eval (i32.const 1000))

			;; skip to expected output
			(local.set $start (i32.add (i32.add (local.get $start) (local.get $len)) (i32.const 1)))
			(local.tee $len (call $strlen (local.get $start)))

			;;(call $print_i32 (local.get $start))
			;;(call $print_i32 (local.get $len))
			;;(call $print_i32 (global.get $output_length))

			(if (i32.ne (global.get $output_length)) (then unreachable))
			(if (call $memcmp (local.get $start) (local.get $len)) (then unreachable))

			;; skip to next input
			(local.set $start (i32.add (i32.add (local.get $start) (local.get $len)) (i32.const 1)))
			br $l
		)
	)

	(func $strlen (param $start i32) (result i32)
		(local $len i32)
		block $done
		(loop $l
			(br_if $done (i32.eqz (i32.load8_u $tests (local.get $start))))
			(local.set $len (i32.add (local.get $len) (i32.const 1)))
			(local.set $start (i32.add (local.get $start) (i32.const 1)))
			br $l
		)
		end $done
		local.get $len
	)

	(func $memcmp (param $src i32) (param $len i32) (result i32)
		(local $dst i32)
		(local $tmp i32)
		block $done
		(loop $l
			(br_if $done (i32.eqz (local.get $len)))

			(i32.load8_u $tests (local.get $src))

			;;(call $print_i32 (local.get $src))
			;;call $trace_i32

			(i32.load8_u $output (local.get $dst))

			;;(call $print_i32 (local.get $dst))
			;;call $trace_i32

			(if (i32.ne) (then
				(return (i32.const 1))
			))
			(local.set $src (i32.add (local.get $src) (i32.const 1)))
			(local.set $dst (i32.add (local.get $dst) (i32.const 1)))
			(local.set $len (i32.sub (local.get $len) (i32.const 1)))
			br $l
		)
		end $done
		i32.const 0
	)
)

(assert_return (invoke "test"))
