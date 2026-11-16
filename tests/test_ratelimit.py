from app.ratelimit import RateLimiter


class Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


def test_limit_and_independent_keys():
    rl = RateLimiter(clock=Clock())
    assert all(rl.allow("a") for _ in range(10))
    assert rl.allow("a") is False
    assert rl.allow("b") is True


def test_window_expires_and_prunes():
    c = Clock()
    rl = RateLimiter(clock=c)
    for _ in range(10):
        rl.allow("a")
    assert rl.allow("a") is False
    c.t += 60
    assert rl.allow("a") is True
    rl.allow("b")
    c.t += 61
    rl.allow("c")
    assert set(rl._hits) == {"c"}
