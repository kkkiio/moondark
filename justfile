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
    moon build examples/todo
    PATH="$PWD/_build/native/debug/build/xziheng/moondark_example_todo:$PATH" moon-cram test examples/todo/tests
