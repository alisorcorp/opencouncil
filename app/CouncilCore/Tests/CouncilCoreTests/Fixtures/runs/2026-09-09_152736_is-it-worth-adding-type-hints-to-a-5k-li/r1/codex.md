**Yes, incrementally—if the codebase will keep changing.** With no tests, I’d first add smoke tests for critical workflows, then annotate functions as you touch them.

Start with shared data structures, function signatures, and places where `None` is possible. Run a type checker in CI; [mypy recommends starting small](https://mypy.readthedocs.io/en/stable/existing_code.html). Avoid refactoring working code solely to satisfy the checker until tests cover its behavior.

Type checking catches some incompatible arguments and unsafe operations. It cannot establish correct business logic, and [Python doesn’t enforce hints at runtime](https://docs.python.org/3/library/typing.html).

The payoff depends on maintenance frequency and typing difficulty. Try one representative module before committing broadly. For rarely changed code, I’d prioritize targeted tests over comprehensive annotations.