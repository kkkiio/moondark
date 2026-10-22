check:
    moon check --deny-warn
fmt:
    moon fmt
    moon info
test:
    moon test

test-core:
    MOON_WORK=off moon -C core test
test-example:
    moon build
    moon cram test examples/todo/tests
